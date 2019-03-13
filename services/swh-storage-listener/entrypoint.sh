#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
      pushd $srcrepo
      pip install -e .
      popd
    done
fi

echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
cat > ~/.pg_service.conf <<EOF
[swh]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

chmod 0600 ~/.pgpass

echo Installed Python packages:
pip list

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Waiting for postgresql to start"
      wait-for-it swh-storage-db:5432 -s --timeout=0

      echo "Starting swh-storage-listener"
      exec wait-for-it kafka:9092 -s --timeout=0 -- python3 -m swh.storage.listener
      ;;
esac
