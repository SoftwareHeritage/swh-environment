#!/bin/bash

set -e
export PATH=${HOME}/.local/bin:${PATH}

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pushd $srcrepo
        echo "WARNING: $srcrepo will NOT be pip installed in dev mode"
        echo "         due to permission limitations."
        pip install --user .
        popd
    done
fi

echo Installed Python packages:
pip list

echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
cat > ~/.pg_service.conf <<EOF
[swh-indexer]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

chmod 0600 ~/.pgpass

case "$1" in
    "shell")
        exec bash -i
        ;;
    *)

    echo Waiting for postgresql to start
    wait-for-it swh-indexer-storage-db:5432 -s --timeout=0

    echo Setup the database
    PGPASSWORD=${POSTGRES_PASSWORD} swh-db-init indexer \
          --db-name ${POSTGRES_DB}

    echo Starting the swh-indexer-storage API server
    exec gunicorn --bind 0.0.0.0:5007 \
         --reload \
         --log-level DEBUG \
         --timeout 3600 \
         swh.indexer.storage.api.wsgi
    ;;
esac
