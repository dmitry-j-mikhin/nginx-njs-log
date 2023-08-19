# syntax=docker/dockerfile:experimental
FROM nginx:1.24.0

LABEL maintainer="Dmitry Mikhin <dmikhin@webmonitorx.ru>"

RUN --mount=type=bind,target=/tmp/build,source=scripts,ro \
    /tmp/build/build.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
