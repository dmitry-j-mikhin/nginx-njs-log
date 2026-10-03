#!/usr/bin/env bash
# Smoke test: starts the image, sends a set of requests and checks the JSON
# records written to the access log.
#
#   test/smoke-test.sh            build nginx-njs-log:test and test it
#   test/smoke-test.sh IMAGE      test an already built image
#
# NJS_LOG_JS_ENGINE=qjs runs the same checks with the QuickJS engine.
# Requires docker, curl and jq.

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE=${1:-nginx-njs-log:test}
ENGINE=${NJS_LOG_JS_ENGINE:-njs}
NAME=nginx-njs-log-test-$$
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

if [ $# -eq 0 ]; then
    docker build --quiet --tag "$IMAGE" . >/dev/null
fi

start() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run --detach --name "$NAME" --publish 127.0.0.1::80 \
        --env NGINX_ENTRYPOINT_QUIET_LOGS=1 --env NJS_LOG_JS_ENGINE="$ENGINE" \
        --env NJS_LOG_ACCESS_LOG=/tmp/access.log \
        "$@" "$IMAGE" >/dev/null

    PORT=$(docker port "$NAME" 80/tcp | head -n 1 | sed 's/.*://')
    URL="http://127.0.0.1:$PORT"

    for _ in $(seq 50); do
        curl --silent --output /dev/null "$URL/" && break
        sleep 0.1
    done

    docker cp "$WORK/www/." "$NAME:/usr/share/nginx/html/"
}

# The access log is written to a file: "docker logs" splits lines longer than
# 16 KiB and may mangle a multi-byte UTF-8 character at the split point.
access_log() {
    docker exec "$NAME" cat /tmp/access.log
}

# All records whose request URI is "/?case=NAME" or ends with "?case=NAME".
record() {
    access_log | jq -c --arg c "case=$1" \
        'select(.request_uri | endswith("?" + $c))'
}

# Waits until the access log has at least N records of test cases.
wait_records() {
    for _ in $(seq 50); do
        [ "$(access_log | grep -c '?case=')" -ge "$1" ] && return
        sleep 0.1
    done
}

check_error_log() {
    if docker logs "$NAME" 2>&1 | grep -E 'njs-log:|js exception|\[(alert|crit|error)\]'; then
        echo "FAIL errors in the error log"
        FAILED=1
    fi
}

check() {
    local desc=$1 case=$2 filter=$3

    if [ "$(record "$case" | jq -s --exit-status "length == 1 and (.[0] | $filter)")" = true ]; then
        echo "ok   $desc"
    else
        echo "FAIL $desc"
        record "$case" | head -c 2000
        echo
        FAILED=1
    fi
}

# Compares a body field, decoded if base64, with the expected bytes.
check_bytes() {
    local desc=$1 case=$2 field=$3 expected=$4

    if record "$case" | jq -j --arg f "$field" '.[$f]' \
            | if [ "$(record "$case" | jq -r --arg f "${field}_base64" '.[$f]')" = true ]; then
                  base64 -d
              else
                  cat
              fi \
            | cmp --silent - "$expected"; then
        echo "ok   $desc"
    else
        echo "FAIL $desc"
        FAILED=1
    fi
}

mkdir -p "$WORK/www"
head -c 100000 /dev/urandom > "$WORK/www/random.bin"
head -c 1000 /dev/urandom > "$WORK/small.bin"
# ~200 KB of two-byte UTF-8 characters, delivered in many chunks; with
# 99-byte lines the 64 KiB cut (661 lines + 97 bytes) splits a character
line=$(printf 'ж%.0s' $(seq 49))
for _ in $(seq 2000); do echo "$line"; done > "$WORK/www/big.txt"
head -n 400 "$WORK/www/big.txt" > "$WORK/40k.txt"
{ head -n 661 "$WORK/www/big.txt"; head -c 96 <<< "$line"; } > "$WORK/big-logged.txt"
# a two-byte character straddles the 64 KiB cut
{ head -c 65535 /dev/zero | tr '\0' a; printf 'é'; head -c 40000 /dev/zero | tr '\0' b; } > "$WORK/100k.txt"
head -c 65535 "$WORK/100k.txt" > "$WORK/100k-logged.txt"
head -c 65536 "$WORK/www/random.bin" > "$WORK/random-logged.bin"

echo "# engine: $ENGINE, image: $IMAGE"
start

curl -s -o /dev/null "$URL/?case=get"
curl -s -o /dev/null "$URL/?case=post" -d 'example request body payload'
curl -s -o /dev/null "$URL/?case=inject" -H 'User-Agent: a", "injected": "1'
curl -s -o /dev/null "$URL/?case=headers" -H 'Authorization: Bearer secret' -H 'Cookie: sid=secret'
curl -s -o /dev/null "$URL/?case=gzip" -H 'Accept-Encoding: gzip'
curl -s -o /dev/null "$URL/?case=small-binary" --data-binary @"$WORK/small.bin"
curl -s -o /dev/null "$URL/?case=file-body" --data-binary @"$WORK/40k.txt"
curl -s -o /dev/null "$URL/?case=big-body" --data-binary @"$WORK/100k.txt"
curl -s -o /dev/null "$URL/random.bin?case=binary"
# two requests on one keepalive connection: the second must not inherit the
# body captured for the first one
curl -s -o /dev/null -o /dev/null "$URL/big.txt?case=keepalive-1" "$URL/?case=keepalive-2"
# a request rejected while reading the headers (duplicate Content-Length)
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
printf 'GET /?case=invalid HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 46\r\n\r\n' >&3
cat <&3 >/dev/null
exec 3<&-

wait_records 12

if access_log | jq -e . >/dev/null; then
    echo "ok   every access log line is valid JSON"
else
    echo "FAIL access log contains invalid JSON"
    access_log | tail -n 5
    FAILED=1
fi

check "GET: status, response body and headers" get \
    '.status == 200 and (.response_body_njs | startswith("<!DOCTYPE html>"))
     and .response_headers_njs["Content-Type"] == "text/html" and .request_body_njs == ""
     and .upstream_addr == "127.0.0.1:8080" and (.request_id | test("^[0-9a-f]{32}$"))
     and (.msec | type) == "number" and (.request_time | type) == "number"
     and (has("response_body_njs_truncated") or has("response_body_njs_base64") | not)'
check "POST: request body" post \
    '.status == 405 and .request_body_njs == "example request body payload"
     and (.response_body_njs | contains("405 Not Allowed"))'
check "JSON injection via User-Agent is escaped" inject \
    '.http_user_agent == "a\", \"injected\": \"1" and (has("injected") | not)'
check "headers are not masked by default" headers \
    '.request_headers_njs.Authorization == "Bearer secret" and .request_headers_njs.Cookie == "sid=secret"'
check "Accept-Encoding is passed upstream by default" gzip \
    '.response_headers_njs["Content-Encoding"] == "gzip" and .response_body_njs_base64 == true
     and (.response_body_njs | startswith("H4sI"))'
check "binary request body is base64" small-binary \
    '.request_body_njs_base64 == true and (has("request_body_njs_truncated") | not)'
check_bytes "binary request body content" small-binary request_body_njs "$WORK/small.bin"
check "request body buffered to a temp file" file-body \
    '(has("request_body_njs_truncated") or has("request_body_njs_base64") | not)'
check_bytes "request body buffered to a temp file: content" file-body request_body_njs "$WORK/40k.txt"
check "large request body is truncated" big-body \
    '.request_body_njs_truncated == true and (has("request_body_njs_base64") | not)'
check_bytes "large request body: cut UTF-8 character is dropped" big-body request_body_njs \
    "$WORK/100k-logged.txt"
check "binary response is base64 and truncated" binary \
    '.response_body_njs_base64 == true and .response_body_njs_truncated == true
     and .body_bytes_sent == 100000'
check_bytes "binary response content" binary response_body_njs "$WORK/random-logged.bin"
check "multi-chunk UTF-8 response is truncated text" keepalive-1 \
    '.response_body_njs_truncated == true and (has("response_body_njs_base64") | not)'
check_bytes "multi-chunk UTF-8 response content" keepalive-1 response_body_njs "$WORK/big-logged.txt"
check "keepalive: no state leaks into the next request" keepalive-2 \
    '(.response_body_njs | startswith("<!DOCTYPE html>"))
     and (.response_body_njs | utf8bytelength) == (.response_headers_njs["Content-Length"] | tonumber)
     and (has("response_body_njs_truncated") | not)'
check "GET without body: no capture state is left behind" keepalive-2 \
    '.request_body_njs == "" and (has("request_body_njs_truncated") | not)'
check "invalid request is still logged as valid JSON" invalid \
    '.status == 400 and .request_body_njs == "" and .upstream_addr == null'

check_error_log

echo "# settings from the environment"
start --env NJS_LOG_BODY_MAX_SIZE=16 --env NJS_LOG_STRIP_ACCEPT_ENCODING=on \
    --env NJS_LOG_REDACT=on --env NJS_LOG_REDACT_HEADERS="cookie, x-api-*" --env NJS_LOG_REDACT_VALUE="***"

curl -s -o /dev/null "$URL/?case=env" -d 'example request body payload' \
    -H 'Cookie: sid=secret' -H 'X-Api-Key: secret' -H 'Authorization: Bearer visible'
curl -s -o /dev/null "$URL/?case=env-gzip" -H 'Accept-Encoding: gzip'
wait_records 2

check "NJS_LOG_BODY_MAX_SIZE" env \
    '.request_body_njs == "example request " and .request_body_njs_truncated == true
     and (.response_body_njs | length) == 16 and .response_body_njs_truncated == true'
check "NJS_LOG_REDACT_HEADERS with a wildcard and NJS_LOG_REDACT_VALUE" env \
    '.request_headers_njs.Cookie == "***" and .request_headers_njs["X-Api-Key"] == "***"
     and .request_headers_njs.Authorization == "Bearer visible"'
check "NJS_LOG_STRIP_ACCEPT_ENCODING=on" env-gzip \
    '.request_headers_njs["Accept-Encoding"] == "gzip" and (.response_headers_njs | has("Content-Encoding") | not)
     and .response_body_njs == "<!DOCTYPE html>\n" and (has("response_body_njs_base64") | not)'

check_error_log

echo "# masking with the default header list"
start --env NJS_LOG_REDACT=on

curl -s -o /dev/null "$URL/?case=redact" -H 'Authorization: Bearer secret' -H 'Cookie: sid=secret' \
    -H 'Proxy-Authorization: Basic c2VjcmV0' -H 'X-Custom: visible'
wait_records 1

check "NJS_LOG_REDACT=on" redact \
    '.request_headers_njs.Authorization == "[redacted]" and .request_headers_njs.Cookie == "[redacted]"
     and .request_headers_njs["Proxy-Authorization"] == "[redacted]" and .request_headers_njs["X-Custom"] == "visible"'

check_error_log

# nothing listens on the syslog port: only the rendered configuration is checked
echo "# syslog defaults"
start --env NJS_LOG_ACCESS_LOG= --env SYSLOG_SRV=syslog:server=127.0.0.1:5514

# shellcheck disable=SC2016  # nginx variables, not shell ones
if docker exec "$NAME" cat /etc/nginx/conf.d/njs-log.conf \
        | grep -qF 'access_log syslog:server=127.0.0.1:5514 njs_json;' \
   && docker exec "$NAME" cat /etc/nginx/conf.d/njs-log.conf \
        | grep -qE 'js_var +\$njs_log_body_max_size +"16k";'; then
    echo "ok   SYSLOG_SRV sets the log destination and a 16k body limit"
else
    echo "FAIL SYSLOG_SRV"
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "# FAILED"
    exit 1
fi

echo "# all checks passed"
