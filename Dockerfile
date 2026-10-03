FROM nginx:1.30.5

LABEL org.opencontainers.image.title="nginx-njs-log" \
      org.opencontainers.image.description="nginx with full request and response (headers + body) JSON logging via njs" \
      org.opencontainers.image.source="https://github.com/dmitry-j-mikhin/nginx-njs-log" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.authors="Dmitry Mikhin <dmikhin@webmonitorx.ru>"

# Runtime settings, see README.md.  Defaults of NJS_LOG_ACCESS_LOG and
# NJS_LOG_BODY_MAX_SIZE depend on each other, see 18-njs-log.envsh.
ENV NJS_LOG_UPSTREAM=http://127.0.0.1:8080 \
    NJS_LOG_REDACT=off \
    NJS_LOG_REDACT_HEADERS="authorization proxy-authorization cookie set-cookie" \
    NJS_LOG_REDACT_VALUE="[redacted]" \
    NJS_LOG_STRIP_ACCEPT_ENCODING=off \
    NJS_LOG_JS_ENGINE=njs \
    NGINX_ENVSUBST_FILTER="^NJS_LOG_"

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx/ /etc/nginx/
COPY --chmod=755 docker-entrypoint.d/ /docker-entrypoint.d/
