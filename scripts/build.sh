set -ex

f=wallarm-4.6.14.x86_64-glibc.sh
curl https://meganode.webmonitorx.ru/4.6/${f} -O
sh ./${f} -- -b --skip-registration --skip-systemd
rm ${f}

sed -i \
 -e '/^events {/i load_module modules/ngx_http_js_module.so;' \
 -e 's|access_log.*|access_log off;|' \
 /etc/nginx/nginx.conf

sed -i \
 -e 's|listen.*|listen 8080;|g' \
 /etc/nginx/conf.d/default.conf
cat /tmp/build/default_addon.conf >> /etc/nginx/conf.d/default.conf

sed -i \
 -e '/exec "$@"/i \
 if [ -n "$SYSLOG_SRV" ]; then\
  sed -i -e "s|/var/log/nginx/access.log|$SYSLOG_SRV|g" /etc/nginx/conf.d/default.conf\
 fi\
 if [ -n "$WALLARM_MODE" ]; then\
  sed -i -e "s|wallarm_mode monitoring|wallarm_mode $WALLARM_MODE|g" /etc/nginx/conf.d/default.conf\
 fi\
 if [ -n "$WALLARM_API_HOST" ]; then\
  args="$args -H $WALLARM_API_HOST"\
 fi\
 if [ -n "$TARANTOOL_MEMORY_GB" ]; then\
  runuser -g wallarm -u wallarm -- sed -i -e "s|SLAB_ALLOC_ARENA=0.2|SLAB_ALLOC_ARENA=$TARANTOOL_MEMORY_GB|g" /opt/wallarm/env.list\
 fi\
 /opt/wallarm/register-node $args\
 /opt/wallarm/supervisord.sh &\
 /wait-for-tarantool.sh' \
 docker-entrypoint.sh

cp /tmp/build/wait-for-tarantool.sh /
cp /tmp/build/logging.js /etc/nginx/
