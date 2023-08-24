set -ex

docker exec -it nginx-njs-log \
 bash -c "
 head -c 5M /dev/zero > /usr/share/nginx/html/5M.bin
 curl 127.1/5M.bin --output /dev/null
 sleep 5
 pidof -d$'\n' nginx | sort -n | xargs -I% bash -c 'cat /proc/%/cmdline ; echo -e \" pid %\" ; cat /proc/%/status | egrep \"Vm(Peak|Size|HWM|RSS)\" | sed \"s|^|  |\"'
 "
