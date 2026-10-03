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
* Values of the headers listed in `NJS_LOG_REDACT_HEADERS` are replaced with `"[redacted]"`.
* If building a record fails, it still is valid JSON and carries an `njs_log_error` field.

## Settings

| Variable | Default | |
|---|---|---|
| `NJS_LOG_UPSTREAM` | `http://127.0.0.1:8080` | where requests are proxied to (`proxy_pass`) |
| `NJS_LOG_ACCESS_LOG` | `/var/log/nginx/access.log` (stdout) or `$SYSLOG_SRV` | log destination, a file or an [nginx syslog target](https://nginx.org/en/docs/syslog.html) |
| `SYSLOG_SRV` | | shortcut for a syslog `NJS_LOG_ACCESS_LOG`, kept for compatibility |
| `NJS_LOG_BODY_MAX_SIZE` | `64k`, `16k` with syslog | bytes kept per body (`k`/`m` suffixes allowed), `0` turns body capture off |
| `NJS_LOG_REDACT_HEADERS` | `authorization proxy-authorization cookie set-cookie` | request and response headers to hide; empty to log everything |
| `NJS_LOG_JS_ENGINE` | `njs` | `js_engine`: `njs` or `qjs` (QuickJS) |

The settings are applied at container start by the stock nginx image entrypoint (`envsubst` on
`/etc/nginx/templates`, see [docker-entrypoint.d/18-njs-log.envsh](docker-entrypoint.d/18-njs-log.envsh)).
Only `NJS_LOG_*` variables are substituted (`NGINX_ENVSUBST_FILTER`), so nginx variables in templates are left alone.
For anything else, mount your own `/etc/nginx/templates/njs-log.conf.template`. The body limit can also be changed
per location, e.g. to stop capturing bodies of file uploads:
```nginx
location /upload/ {
    set $njs_log_body_max_size 0;
    ...
}
```

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

* **Sensitive data.** Bodies are logged as they are: passwords, tokens and personal data in request or response
  bodies end up in the log. Only the headers from `NJS_LOG_REDACT_HEADERS` are hidden.
* **Memory.** The whole request body is read into worker memory before it is proxied (bounded by
  `client_max_body_size`, 1m by default), and up to `NJS_LOG_BODY_MAX_SIZE` of each body is kept until the
  record is written. `proxy_request_buffering off` has no effect in a location with `js_access`.
  Turn capture off (`set $njs_log_body_max_size 0;`) for locations with large uploads or downloads.
* **Temporary files.** A request body larger than `client_body_buffer_size` (16k) is buffered to disk by nginx
  and read back by njs, which logs `http js reading request body from a temporary file` at the `warn` level.
  Raise `client_body_buffer_size` to keep such bodies in memory.
* **Compression.** `Accept-Encoding` is removed from proxied requests so that the upstream answers uncompressed
  and the logged body is readable. Enable `gzip` in nginx if clients should still get compressed responses.
* **`docker logs`.** Docker splits log lines longer than 16 KiB, and the `json-file` driver may replace
  a multi-byte UTF-8 character at a split point with `U+FFFD`. Log to a file on a volume when records are large.

[ANALYSIS.md](ANALYSIS.md) has a longer review of the approach, its trade-offs and the alternatives.

## Development

* `./test/smoke-test.sh` builds the image and checks the log records for a set of requests (text, binary,
  large and invalid requests, header redaction, JSON injection); `NJS_LOG_JS_ENGINE=qjs ./test/smoke-test.sh`
  runs the same checks with QuickJS. CI runs both on every push and pull request.
* `./build_push.sh` runs the smoke test, then builds `linux/amd64` and `linux/arm64` images and pushes them as
  `latest` and `<nginx version>`.
* Dependabot proposes nginx patch releases and GitHub Actions updates. Moving to the next stable branch
  (1.32) is a manual change of the `FROM` line.
