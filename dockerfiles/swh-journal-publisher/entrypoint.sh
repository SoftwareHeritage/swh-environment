#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
      pushd $srcrepo
      pip install -e .
      popd
    done
fi

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Starting swh-journal publisher"
      exec python3 -m swh.journal.publisher
      ;;
esac
