set -ex

sed -i \
 -e '/^events {/i load_module modules/ngx_http_js_module.so;' \
 -e 's|access_log.*|access_log off;|' \
 /etc/nginx/nginx.conf

sed -i \
 -e 's|listen.*|listen 8080;|g' \
 /etc/nginx/conf.d/default.conf
cat /tmp/default_addon.conf >> /etc/nginx/conf.d/default.conf

sed -i \
 -e '/exec "$@"/i \
 if [ -n "$SYSLOG_SRV" ]; then\
  sed -i -e "s|/var/log/nginx/access.log|$SYSLOG_SRV|g" /etc/nginx/conf.d/default.conf\
 fi' \
 docker-entrypoint.sh

cp /tmp/logging.js /etc/nginx/
