# nginx-njs-log

Example [docker image](https://hub.docker.com/r/dmikhin/nginx-njs-log) based on the official
[nginx:1.30.5](https://hub.docker.com/_/nginx/) stable image (Debian trixie, [njs](https://nginx.org/en/docs/njs/) 1.0.1)
that logs full requests (headers + body) and responses (headers + body) as one JSON record per request.

How it works:
* [nginx/njs/logging.js](nginx/njs/logging.js) builds the whole record and serializes it with `JSON.stringify()`,
  so no client-controlled value is ever written to the log unescaped;
* [nginx/templates/njs-log.conf.template](nginx/templates/njs-log.conf.template) wires it into nginx:
  `js_access` captures the request body before it is proxied, `js_body_filter` captures the response body,
  and a `js_set` variable is the only thing in the `log_format`.

## Quick start

```shell
$ docker build -t dmikhin/nginx-njs-log .   # or use the image from Docker Hub
$ ./run.sh
```

Send an example request:
```shell
$ curl 127.0.0.1 -d "example request body payload"
```

The latest log record formatted with [jq](https://github.com/jqlang/jq), `docker logs --tail 1 nginx-njs-log | jq`:
```json
{
  "source": "nginx",
  "msec": 1791014065.887,
  "time_iso8601": "2026-10-03T07:54:25+00:00",
  "request_id": "9362e093986fbc3c90bb2e280abdf050",
  "request_time": 0.001,
  "body_bytes_sent": 157,
  "bytes_sent": 314,
  "request_length": 170,
  "http_host": "127.0.0.1",
  "http_user_agent": "curl/8.5.0",
  "remote_addr": "172.17.0.1",
  "request_method": "POST",
  "request_uri": "/",
  "status": 405,
  "upstream_addr": "127.0.0.1:8080",
  "request_body_njs": "example request body payload",
  "response_body_njs": "<html>\r\n<head><title>405 Not Allowed</title></head>\r\n<body>\r\n<center><h1>405 Not Allowed</h1></center>\r\n<hr><center>nginx/1.30.5</center>\r\n</body>\r\n</html>\r\n",
  "request_headers_njs": {
    "Host": "127.0.0.1",
    "User-Agent": "curl/8.5.0",
    "Accept": "*/*",
    "Content-Length": "28",
    "Content-Type": "application/x-www-form-urlencoded"
  },
  "response_headers_njs": {
    "Content-Type": "text/html",
    "Content-Length": "157"
  }
}
```

By default the image proxies to a built-in demo upstream (the nginx welcome page). To log the traffic of a real
service, point `NJS_LOG_UPSTREAM` at it:
```shell
$ docker run --rm -p 80:80 -e NJS_LOG_UPSTREAM=http://app:3000 --network my-net dmikhin/nginx-njs-log
```

## Record format

* Fields of nginx variables (`msec`, `status`, `http_user_agent`, ...) are numbers or strings; a variable that
  has no value (e.g. `upstream_addr` when nginx answered by itself) is `null`.
* `request_body_njs` / `response_body_njs` hold the body as text when it is valid UTF-8, otherwise as base64,
  marked with `"request_body_njs_base64": true` / `"response_body_njs_base64": true`.
* Bodies longer than `NJS_LOG_BODY_MAX_SIZE` are cut and marked with `"..._truncated": true`.
  A UTF-8 character split by the cut is dropped.
* With `NJS_LOG_REDACT=on`, values of the headers matching `NJS_LOG_REDACT_HEADERS` are replaced with
  `NJS_LOG_REDACT_VALUE`, see [Header masking](#header-masking).
* If building a record fails, it still is valid JSON and carries an `njs_log_error` field.

## Settings

| Variable | Default | |
|---|---|---|
| `NJS_LOG_UPSTREAM` | `http://127.0.0.1:8080` | where requests are proxied to (`proxy_pass`) |
| `NJS_LOG_ACCESS_LOG` | `/var/log/nginx/access.log` (stdout) or `$SYSLOG_SRV` | log destination, a file or an [nginx syslog target](https://nginx.org/en/docs/syslog.html) |
| `SYSLOG_SRV` | | shortcut for a syslog `NJS_LOG_ACCESS_LOG`, kept for compatibility |
| `NJS_LOG_BODY_MAX_SIZE` | `64k`, `16k` with syslog | bytes kept per body (`k`/`m` suffixes allowed), `0` turns body capture off |
| `NJS_LOG_REDACT` | `off` | `on` masks the values of the headers below, see [Header masking](#header-masking) |
| `NJS_LOG_REDACT_HEADERS` | `authorization proxy-authorization cookie set-cookie` | request and response headers to mask |
| `NJS_LOG_REDACT_VALUE` | `[redacted]` | text logged instead of a masked value (no `"` or `$`: it goes into nginx config) |
| `NJS_LOG_STRIP_ACCEPT_ENCODING` | `off` | `on` removes `Accept-Encoding` from proxied requests, see [Compression](#compression) |
| `NJS_LOG_JS_ENGINE` | `njs` | `js_engine`: `njs` or `qjs` (QuickJS) |

The settings are applied at container start by the stock nginx image entrypoint (`envsubst` on
`/etc/nginx/templates`, see [docker-entrypoint.d/18-njs-log.envsh](docker-entrypoint.d/18-njs-log.envsh)).
Only `NJS_LOG_*` variables are substituted (`NGINX_ENVSUBST_FILTER`), so nginx variables in templates are left alone.
For anything else, mount your own `/etc/nginx/templates/njs-log.conf.template`.

`NJS_LOG_BODY_MAX_SIZE`, `NJS_LOG_REDACT*` and `NJS_LOG_STRIP_ACCEPT_ENCODING` become the nginx variables
`$njs_log_body_max_size`, `$njs_log_redact`, ... and can be changed per server or location with `set`:
```nginx
location /upload/ {
    set $njs_log_body_max_size 0;       # do not capture bodies of file uploads
    ...
}

location /api/ {
    set $njs_log_redact on;
    set $njs_log_redact_headers "authorization x-api-*";
    set $njs_log_strip_accept_encoding on;
    ...
}
```
A location of your own needs the `js_access`, `js_body_filter` and `proxy_set_header Accept-Encoding
$njs_log_accept_encoding` lines of the `location /` from the template.

### Header masking

Masking is off by default: every header is logged as it is. With `NJS_LOG_REDACT=on` the values of matching
request and response headers are replaced with `NJS_LOG_REDACT_VALUE`:
```shell
$ docker run --rm -p 80:80 -e NJS_LOG_REDACT=on \
    -e NJS_LOG_REDACT_HEADERS="authorization cookie set-cookie x-api-* *-token" \
    -e NJS_LOG_REDACT_VALUE="***" dmikhin/nginx-njs-log
```
`NJS_LOG_REDACT_HEADERS` is a list of header names separated by spaces or commas, matched case-insensitively;
`*` matches any part of a name. Only headers are masked: bodies and the query string are logged as they are.

### Compression

By default `Accept-Encoding` is passed to the upstream unchanged. When the upstream compresses its answer, the
logged response body is the compressed bytes in base64 and `response_headers_njs` has `Content-Encoding`.
The demo upstream does this too, so a request from a browser is logged with a gzip body.

`NJS_LOG_STRIP_ACCEPT_ENCODING=on` removes `Accept-Encoding` from proxied requests, the upstream answers
uncompressed and the logged body is readable. Traffic between nginx and the upstream grows accordingly. To keep
compression for clients, enable `gzip` in the logging `server`: nginx compresses the response after
`js_body_filter` has captured it.

### Syslog

```shell
$ SYSLOG_SRV="syslog:server=172.17.0.1:5514,facility=local7,tag=nginx,severity=info" ./run.sh
```
Syslog output using [syslog2stdout](https://github.com/ossobv/syslog2stdout):
```shell
$ ./syslog2stdout 5514
172.17.0.2:52961: local7.info: nginx-njs-log nginx: {"source":"nginx","msec":1791014065.887,"time_iso8601":"2026-10-03T07:54:25+00:00",...}
```
nginx sends every record as a single UDP datagram, and a record that does not fit into 64 KiB is dropped with
a `send() failed (90: Message too long)` alert. That is why the default body limit is 16k with syslog. Large
headers can still push a record over the limit; for complete logs prefer a file and a log shipper.

## Caveats

* **Sensitive data.** Nothing is masked by default: credentials and personal data in headers, bodies and the
  query string end up in the log. `NJS_LOG_REDACT=on` masks headers only.
* **Memory.** The whole request body is read into worker memory before it is proxied (bounded by
  `client_max_body_size`, 1m by default), and up to `NJS_LOG_BODY_MAX_SIZE` of each body is kept until the
  record is written. `proxy_request_buffering off` has no effect in a location with `js_access`.
  Turn capture off (`set $njs_log_body_max_size 0;`) for locations with large uploads or downloads.
* **Temporary files.** A request body larger than `client_body_buffer_size` (16k) is buffered to disk by nginx
  and read back by njs, which logs `http js reading request body from a temporary file` at the `warn` level.
  Raise `client_body_buffer_size` to keep such bodies in memory.
* **`docker logs`.** Docker splits log lines longer than 16 KiB, and the `json-file` driver may replace
  a multi-byte UTF-8 character at a split point with `U+FFFD`. Log to a file on a volume when records are large.

[ANALYSIS.md](ANALYSIS.md) has a longer review of the approach, its trade-offs and the alternatives.

## Development

* `./test/smoke-test.sh` builds the image and checks the log records for a set of requests (text, binary,
  large and invalid requests, header masking, `Accept-Encoding` handling, JSON injection); `NJS_LOG_JS_ENGINE=qjs ./test/smoke-test.sh`
  runs the same checks with QuickJS. CI runs both on every push and pull request.
* `./build_push.sh` runs the smoke test, then builds `linux/amd64` and `linux/arm64` images and pushes them as
  `latest` and `<nginx version>`.
* Dependabot proposes nginx patch releases and GitHub Actions updates. Moving to the next stable branch
  (1.32) is a manual change of the `FROM` line.
