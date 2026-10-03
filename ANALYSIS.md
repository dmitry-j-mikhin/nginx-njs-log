# Analysis: full request/response logging in nginx

Review notes for the approach implemented in this repository — what it costs, where it
breaks, what the alternatives are, and why nginx core still has nothing comparable.

* Reviewed: 2026-07-23
* Repository state: commit `bfc5ad5` (nginx `1.26.2`, njs body filter with `buffer_type=buffer`)
* Upstream versions checked: nginx **1.31.3** (15 Jul 2026), njs **1.0.0** (23 Jun 2026)

> **Update 2026-10-03.** The image has since moved to nginx **1.30.5** (stable) with njs **1.0.1**, and most
> findings below are addressed. The rest of this document describes the reviewed commit `bfc5ad5` and is
> kept as is, apart from the corrections marked in 2.4, 2.5 and 2.8.
>
> | Finding | Status |
> |---|---|
> | 2.1 forgeable JSON | fixed: the whole record is built by `JSON.stringify()` in njs, `log_format` holds one `js_set` variable |
> | 2.2 binary payloads | fixed: bodies that are not valid UTF-8 are logged as base64 with a `_base64` marker |
> | 2.3 no size cap | fixed: `NJS_LOG_BODY_MAX_SIZE` (64k) per body with a `_truncated` marker, `0` turns capture off, overridable per location |
> | 2.4 syslog | corrected below; the default body limit is 16k when logging to syslog |
> | 2.5 blocking disk I/O | fixed: `client_body_in_file_only` and `readFileSync` are gone, the body is read by `js_access` + `r.readRequestArrayBuffer()` |
> | 2.6 compressed responses | fixed: `Accept-Encoding` is removed from proxied requests |
> | 2.7 zero-copy | inherent to body capture, unchanged |
> | 2.8 module-level state | fixed: state is owned by the request and dropped after logging; this mattered for QuickJS |
> | 2.9 privacy | partly: `Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie` are redacted by default; bodies are not masked |

---

## 1. What this repository does

Two moving parts:

* [`scripts/default_addon.conf`](https://github.com/dmitry-j-mikhin/nginx-njs-log/blob/bfc5ad5/scripts/default_addon.conf) — a `log_format json escape=none`
  template that mixes plain nginx variables with four `js_set` variables, plus
  `client_body_in_file_only clean` and a `js_body_filter` on `location /`.
* [`scripts/logging.js`](https://github.com/dmitry-j-mikhin/nginx-njs-log/blob/bfc5ad5/scripts/logging.js) — `JSON.stringify` over `r.headersIn` /
  `r.headersOut`, a `readFileSync` of `$request_body_file`, and a body filter that
  accumulates every response chunk into a module-level array which is joined at log time.

It is the smallest thing that works on stock nginx + njs, with no extra modules to build.
That is its main virtue. The rest of this document is the price.

---

## 2. Findings

### 2.1 `escape=none` makes the JSON forgeable — *high*

`log_format ... escape=none` disables escaping for **every** field, but only the four njs
variables are passed through `JSON.stringify`. These five are interpolated raw:

`$http_host`, `$http_user_agent`, `$request_uri`, `$remote_addr`, `$upstream_addr`

Three of them are attacker-controlled. A single double quote breaks the record, and a
crafted value can inject arbitrary JSON keys into the log stream:

```shell
curl 127.0.0.1 -H 'User-Agent: a", "injected": "1'
```

Anything downstream that parses these logs (jq, Filebeat, Vector, a SIEM) either drops the
line or ingests the forged fields. `escape=json` is **not** a fix — it would escape the njs
variables too and turn the embedded objects into strings. The only robust fix is to build
the entire log line inside njs and emit it via a single `js_set` variable.

### 2.2 Binary payloads are still corrupted — *medium*

[`scripts/logging.js:23`](https://github.com/dmitry-j-mikhin/nginx-njs-log/blob/bfc5ad5/scripts/logging.js#L23) calls `data.toString()`, which decodes as UTF-8. Since njs 0.8.5,
bytes that are invalid UTF-8 are replaced with U+FFFD — the replacement is lossy and
irreversible. `buffer_type=buffer` (added in `bfc5ad5`) changed what the filter receives, not
how it is decoded. The same applies to request bodies: `readFileSync(..., 'utf8')` at
[`scripts/logging.js:11`](https://github.com/dmitry-j-mikhin/nginx-njs-log/blob/bfc5ad5/scripts/logging.js#L11) mangles any binary multipart upload.

There is also a size amplification: each U+FFFD becomes a 6-character `�` escape in the
JSON output, so a 1 MB binary response can produce several MB of log.

If byte fidelity matters, accumulate `Buffer` objects and emit
`Buffer.concat(arr).toString('base64')` once at log time. Better still, skip body capture
entirely for `image/*`, `video/*`, `application/octet-stream` and friends.

### 2.3 No size cap anywhere — *high*

The response body is accumulated in full, in worker memory, with no ceiling. A single large
download is held in RAM per in-flight request, and the peak is roughly 3–4× the body size:
the chunk array, the `join('')` copy, the `JSON.stringify` copy, and nginx copying the
variable into the log buffer. Streaming responses (SSE, long-polling, chunked event
streams) grow without bound for the lifetime of the connection.

njs 1.0.0 bounded chained-buffer growth so that it raises a catchable `RangeError` instead
of exhausting worker memory — that is a backstop against OOM, not a substitute for an
explicit cap plus a `truncated` flag.

### 2.4 The syslog mode advertised in the README silently truncates — *high*

nginx clamps every syslog message in `ngx_syslog_writer()`:

```c
#define NGX_SYSLOG_MAX_STR                                                    \
    NGX_MAX_ERROR_STR + sizeof("<255>Jan 01 00:00:00 ") - 1                   \
    + (NGX_MAXHOSTNAMELEN - 1) + 1 /* space */                                \
    + 32 /* tag */ + 2 /* colon, space */

if (len > NGX_SYSLOG_MAX_STR - head_len) {
    len = NGX_SYSLOG_MAX_STR - head_len;
}
```

`NGX_MAX_ERROR_STR` is 2048, so the usable payload is around 2 KB. Bodies larger than that
are cut off with no error and no marker — the record simply ends mid-string and is no longer
valid JSON. Datagrams of that size also fragment on a typical MTU, which adds silent loss.
The `SYSLOG_SRV` example in the README is therefore only honest for small bodies.

> **Correction (2026-10-03).** The clamp above is in `ngx_syslog_writer()`, which serves
> `error_log` only. `access_log` formats the line itself and passes it to `ngx_syslog_send()`
> unclamped: with nginx 1.30.5 a 38 KB record arrived intact. The real limit is the UDP
> datagram: a record over ~64 KiB is not truncated but dropped as a whole, with
> `[alert] send() failed (90: Message too long) while logging to syslog`. The image now
> defaults to a 16k body limit when it logs to syslog.

### 2.5 Blocking disk I/O on every request — *medium*

`client_body_in_file_only clean` forces **every** request body to disk, even a 20-byte form
post, and `readFileSync` reads it back synchronously inside the worker's event loop during
the log phase. That is an open/write/close/read/unlink cycle per request with a body, plus a
synchronous read that stalls the worker.

It also makes `proxy_request_buffering off` unusable, so request streaming to the upstream
is off the table for this server block.

Since njs **0.8.10**, `r.requestText` / `r.requestBuffer` read from the temporary file
themselves, and since **0.9.9** there are async `r.readRequestText()` /
`r.readRequestArrayBuffer()` / `r.readRequestJSON()` / `r.readRequestForm()`. On a modern
base image the whole `readFileSync` + `client_body_in_file_only` construct can go away.
Note that the njs shipped with `nginx:1.26.2` predates 0.8.10 — check the actual module
version before relying on these.

> **Correction (2026-10-03).** `r.requestText` / `r.requestBuffer` do **not** help in the log
> phase. A temporary body file is created unlinked, and nginx closes it as soon as the body has
> been sent upstream; reading `r.requestBuffer` from `js_set` afterwards fails with
> `pread() ... failed (9: Bad file descriptor)` at the `crit` level. Bodies that stayed in
> memory (up to `client_body_buffer_size`) are still readable. The working replacement is to
> read the body earlier with `js_access` and the async `r.readRequestArrayBuffer()` (0.9.9+),
> which is what the image does now; it costs the whole body in worker memory, bounded by
> `client_max_body_size`.

### 2.6 Compressed upstream responses are logged as gzip bytes — *medium*

The body filter sees what the upstream sent. If the backend compresses, the log gets gzip
bytes, which then go through the UTF-8 mangling of 2.2 and become unreadable garbage. For
any location where bodies are captured, add:

```nginx
proxy_set_header Accept-Encoding "";
```

### 2.7 Zero-copy is disabled for the filtered location — *low*

Every output buffer is routed through the JS VM, so `sendfile`/`aio` fast paths do not apply
to `location /`. For a proxy-only workload this is minor; for static or cached content it is
a measurable regression.

### 2.8 Module-level state survives internal redirects and subrequests — *low*

njs creates one VM per request, so `response_body_arr` does not leak between requests. It
does, however, persist across internal redirects (`error_page`, `try_files`,
`X-Accel-Redirect`) and subrequests within the same request, and the bodies of both passes
are concatenated into one log field. Keeping the accumulator in `r.ctx`, or resetting it on
the first chunk, avoids the mixing.

> **Correction (2026-10-03).** "Does not leak between requests" holds for the default njs
> engine only. With `js_engine qjs` (QuickJS, njs 0.8.6+) contexts are reused between requests
> (`js_context_reuse`), module-level variables keep their values, and bodies of earlier requests
> show up in later records. The smoke test reproduces this when the state reset is removed.
> The image now ties the state to the request object and drops it once the record is written.

### 2.9 Privacy and compliance — *high, contextual*

Full-body capture writes passwords, session cookies, bearer tokens, PANs and personal data
into the log stream verbatim. Under PCI DSS or GDPR that is an incident by itself, and it
propagates to every system the logs are shipped to. Any real deployment needs field
masking, a path allow/deny list, and a retention policy — none of which this example has,
and the README does not warn about it.

---

## 3. If the njs approach is kept

Ordered roughly by value per unit of effort:

1. **Sample or filter.** Most of the cost disappears if bodies are captured only for
   `4xx`/`5xx`, for a specific path prefix, or for 1 % of traffic. `access_log ... if=$var`
   plus an early bail-out inside the body filter itself (do not accumulate at all when the
   decision is already "no") is the single biggest win.
2. **Hard cap plus a `truncated` flag.** Stop accumulating past N KB and record that the
   value was cut, so consumers can tell truncation from a genuinely short body.
3. **Build the whole JSON object in njs**, emitted through one `js_set` variable — removes
   finding 2.1 entirely.
4. **Content-Type allow-list** for body capture; base64 (via `Buffer.concat`) for whatever
   binary is still worth keeping.
5. **Bump the base image** to nginx 1.28/1.29 for njs 0.9.x/1.0, then drop `readFileSync` and
   `client_body_in_file_only` in favour of `r.requestText` / `r.readRequestText()`.
6. **Buffer the access log**: `access_log ... buffer=64k flush=1s` (optionally `gzip`),
   and prefer a file plus a shipper over syslog given finding 2.4.
7. **Consider not using `access_log` at all.** With `js_shared_dict_zone` (0.8.0+) and
   `js_periodic` (0.8.1+) the records can be batched and pushed to a collector via
   `ngx.fetch` from a background task, off the request path.

---

## 4. Alternatives

| Approach | Mechanism | Fits when |
|---|---|---|
| **OpenResty / ngx_lua** | `body_filter_by_lua_block` + `ngx.ctx` — the same idea, but on LuaJIT, and the record can be shipped straight to Kafka/ClickHouse (`lua-resty-kafka`) instead of the access log | long-lived infrastructure; costs a separate build, lags mainline nginx, no HTTP/3 |
| **`ngx_http_mirror_module`** (core, since 1.13.4) | asynchronously duplicates the request — method, URI, headers, body — to a sink location; mirror responses are discarded | the **request** side only; this is the closest thing to a native answer, and it does not touch the client's response path |
| **ModSecurity v3 / Coraza** | `SecAuditEngine` + `SecResponseBodyAccess On` gives a full audit log with both bodies, JSON output and real limits (`SecResponseBodyLimit`) | a WAF is wanted anyway; deploying one purely for logging is heavy |
| **Envoy HTTP tap filter** | purpose-built for exactly this: request + response capture with `max_buffered_rx_bytes`/`max_buffered_tx_bytes`, match conditions (only 5xx, only a path), streaming to a file or a gRPC sink, bodies as bytes/base64 | the proxy is a free choice — this is the most mature implementation of the requirement |
| **APISIX / Kong** | `kafka-logger` / `http-logger` / `clickhouse-logger` plugins with `include_req_body` / `include_resp_body` and conditional expressions | configuration instead of code; still OpenResty underneath |
| **eBPF (Pixie, Coroot) / GoReplay** | capture outside nginx; uprobes on OpenSSL yield plaintext with no configuration change at all | zero impact on the nginx config and request latency; costs operational complexity and drops traffic under load |
| **Application-side middleware** | log bodies where the schema, types and business context already exist | very often the cheapest and the safest option |

A note on intent: if the goal is security analysis rather than debugging, the WAF-node
architecture — serialize the request into a separate post-analytics daemon, off the logging
path — is the right shape, and the access log is the wrong transport regardless of how the
bodies are captured.

---

## 5. Why nginx core has no such feature

The reasons are architectural, not neglect:

* **Memory model.** A response body travels the filter chain as a chain of buffers, often
  file buffers (`sendfile`) or buffers owned by the cache. It is never materialised in full.
  Logging it requires materialising it, which contradicts nginx's guarantee of bounded,
  predictable memory per connection.
* **Where the access log lives.** `access_log` is written in the log phase from variables,
  and variables live in the request pool. That pool was never meant to hold megabytes of
  payload.
* **Privacy.** A default that writes credentials into log files is not shippable, and a
  non-default with all the necessary qualifiers — size limits, masking, content-type rules,
  retention — is a policy-bearing module, not a core directive.
* **Project philosophy.** Core stays minimal; extension happens in modules. Core provides
  the primitives only: `$request_body` (in-memory bodies only), `client_body_in_file_only`,
  `ngx_http_mirror_module`, and the njs/lua extension points. Core development is also
  conservative, and since the 2024 fork (freenginx) F5's attention has been on QUIC/HTTP3,
  TLS and OpenTelemetry.

---

## 6. Upstream state as of July 2026

Nothing native has appeared. Reading `CHANGES` through **1.31.3** (15 Jul 2026), the 1.27–1.31
line added `max_headers`, upstream `sticky` sessions, upstream `keepalive` on by default,
`add_header_inherit` / `add_trailer_inherit`, HTTP 103 early hints, `$request_port`,
`ssl_certificate_compression` and certificate caching — nothing that captures bodies. The
official `ngx_otel_module` emits traces, not payloads.

The movement is all in njs:

* **0.8.0** — `js_shared_dict_zone` (cross-worker shared dictionaries)
* **0.8.1** — `js_periodic` (background tasks)
* **0.8.2** — `console.log` and friends
* **0.8.5** — `buffer_type` on `js_body_filter`; invalid UTF-8 → replacement characters
* **0.8.6** — QuickJS engine as an alternative to the built-in VM
* **0.8.10** — `r.requestText` / `r.requestBuffer` can read from the temporary file
* **0.9.9** — async `r.readRequestText()` / `readRequestArrayBuffer()` / `readRequestJSON()` /
  `readRequestForm()`
* **1.0.0** — bounded chained-buffer growth raises a catchable `RangeError` instead of
  exhausting worker memory

So the njs route keeps getting better, but the fundamental trade-off — materialise the body
in worker memory to log it — is unchanged and is not going to change.

---

## References

* [nginx CHANGES](https://nginx.org/en/CHANGES)
* [njs Changes](https://nginx.org/en/docs/njs/changes.html)
* [Module ngx_http_js_module](https://nginx.org/en/docs/http/ngx_http_js_module.html)
* [njs Reference](https://nginx.org/en/docs/njs/reference.html)
* [Module ngx_http_mirror_module](https://nginx.org/en/docs/http/ngx_http_mirror_module.html)
* [nginx syslog logging](https://nginx.org/en/docs/syslog.html)
* [`src/core/ngx_syslog.c`](https://github.com/nginx/nginx/blob/master/src/core/ngx_syslog.c)
* [Envoy HTTP tap filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/tap_filter)
