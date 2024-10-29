set -ex

docker build --pull --no-cache \
 --tag dmikhin/nginx-njs-log:latest .
docker push dmikhin/nginx-njs-log:latest
