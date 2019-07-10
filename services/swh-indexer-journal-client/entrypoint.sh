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
      echo "Starting swh-indexer-journal client"
      exec wait-for-it kafka:9092 -s --timeout=0 -- swh indexer --config-file /etc/softwareheritage/indexer/journal_client.yml journal-client
      ;;
esac

