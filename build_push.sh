set -ex

DOCKER_BUILDKIT=1 docker build --pull \
 --tag dmikhin/nginx-njs-log:test .
docker push dmikhin/nginx-njs-log:test
