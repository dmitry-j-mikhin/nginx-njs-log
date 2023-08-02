set -ex

DOCKER_BUILDKIT=1 docker build --pull \
 --tag dmikhin/nginx-njs-log:wmx .
docker push dmikhin/nginx-njs-log:wmx
