set -ex

if ! getent group wallarm >/dev/null; then
  groupadd --system \
   wallarm 2>&1 >/dev/null
fi
if ! getent passwd wallarm >/dev/null; then
  useradd --system --gid wallarm \
   --home /opt/wallarm \
   --comment "Wallarm system user" \
   wallarm 2>&1 >/dev/null
fi

curl https://meganode.webmonitorx.ru/4.6/wallarm-4.6.12.x86_64-glibc.sh -O
sh ./wallarm-4.6.12.x86_64-glibc.sh --noexec --target /opt/wallarm
chmod a+x /opt/wallarm
rm wallarm-4.6.12.x86_64-glibc.sh
find /opt/wallarm/modules \
    ! -wholename '/opt/wallarm/modules/stable-1240/*' \
    \( -type f -o -type l \) -delete
find /opt/wallarm/modules -empty -type d -delete
rm /opt/wallarm/setup.sh
chown -R wallarm:wallarm /opt/wallarm

cat << 'EOF' | tee "/etc/nginx/wallarm-status.conf" >/dev/null
# wallarm-status, required for monitoring purposes.

# Default `wallarm-status` configuration.
# It is strongly advised not to alter any of the existing lines of the default
# wallarm-status configuration as it may corrupt the process of metric data
# upload to the Wallarm cloud.

server {
  listen 127.0.0.8:80;

  server_name localhost;

  allow 127.0.0.0/8;
  deny all;

  wallarm_mode off;
  disable_acl "on";
  access_log off;

  location ~/wallarm-status$ {
    wallarm_status on;
  }
}
EOF

sed -i \
 -e '/^events {/i load_module /opt/wallarm/modules/stable-1240/ngx_http_wallarm_module.so;' \
 -e '/^http {/a include /etc/nginx/wallarm-status.conf;' \
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
 runuser -g wallarm -u wallarm -- /opt/wallarm/register-node $args\
 chroot --userspec=wallarm:wallarm / /opt/wallarm/supervisord.sh &\
 /wait-for-it.sh -t 60 127.0.0.1:3313' \
 docker-entrypoint.sh

cp /tmp/wait-for-it.sh /
cp /tmp/logging.js /etc/nginx/
