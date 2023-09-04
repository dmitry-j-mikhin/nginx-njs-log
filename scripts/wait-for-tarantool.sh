#!/usr/bin/env bash

echo "Waiting for Tarantool to be available at 127.0.0.1:3313"
while :
do
  (echo -n > /dev/tcp/127.0.0.1/3313) >/dev/null 2>&1 && { echo "127.0.0.1:3313 is available"; break; }
  sleep 1
done
