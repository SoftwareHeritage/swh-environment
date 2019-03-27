#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
      pushd $srcrepo
      pip install -e .
      popd
    done
fi

echo Installed Python packages:
pip list

source /swh-utils/pgsql.sh

wait_pgsql

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      wait_pgsql

      echo "Starting swh-storage-listener"
      exec wait-for-it kafka:9092 -s --timeout=0 -- python3 -m swh.storage.listener
      ;;
esac
