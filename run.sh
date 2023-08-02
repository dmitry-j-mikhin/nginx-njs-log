set -ex

#SYSLOG_SRV="syslog:server=172.17.0.1:5514,facility=local7,tag=nginx,severity=info"
docker run -it --rm \
 --name nginx \
 -e SYSLOG_SRV \
 -p 80:80 \
 dmikhin/nginx-njs-log:latest
