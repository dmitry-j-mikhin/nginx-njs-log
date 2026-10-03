#!/bin/sh
# Runs the image in the foreground; the JSON access log goes to stdout.
#
# Settings are taken from the environment when set, e.g.:
#   SYSLOG_SRV="syslog:server=172.17.0.1:5514,facility=local7,tag=nginx,severity=info" ./run.sh
#   NJS_LOG_UPSTREAM=http://172.17.0.1:3000 NJS_LOG_BODY_MAX_SIZE=4k PORT=8080 ./run.sh

set -ex

docker run -it --rm \
 --name nginx-njs-log \
 --hostname nginx-njs-log \
 -e SYSLOG_SRV \
 -e NJS_LOG_UPSTREAM \
 -e NJS_LOG_ACCESS_LOG \
 -e NJS_LOG_BODY_MAX_SIZE \
 -e NJS_LOG_REDACT \
 -e NJS_LOG_REDACT_HEADERS \
 -e NJS_LOG_REDACT_VALUE \
 -e NJS_LOG_STRIP_ACCEPT_ENCODING \
 -e NJS_LOG_JS_ENGINE \
 -p "${PORT:-80}:80" \
 "${IMAGE:-dmikhin/nginx-njs-log:latest}"
