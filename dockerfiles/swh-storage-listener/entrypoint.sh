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
      until psql postgresql:///?service=swh -c "select 1" 1>&2 >/dev/null; do sleep 0.1; done

      echo "Starting swh-storage's listener"
      exec python3 -m swh.storage.listener
      ;;
esac
