set -ex

#SYSLOG_SRV="syslog:server=172.17.0.1:5514,facility=local7,tag=nginx,severity=info"
docker run -it --rm \
 --name nginx-njs-log \
 --hostname nginx-njs-log \
 -e "TARANTOOL_MEMORY_GB=1" \
 -e "WALLARM_MODE=block" \
 -e "WALLARM_API_HOST=api.wallarm.ru" \
 -e WALLARM_API_TOKEN \
 -e SYSLOG_SRV \
 -p 80:80 \
 dmikhin/nginx-njs-log:wmx
