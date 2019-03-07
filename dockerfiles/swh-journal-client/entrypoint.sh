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

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Starting an swh-journal client"
      exec wait-for-it kafka:9092 -s --timeout=0 -- python3 -m client
      ;;
esac
