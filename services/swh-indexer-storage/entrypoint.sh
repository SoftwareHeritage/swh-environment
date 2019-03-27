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

source /swh-utils/pgsql.sh

setup_pgsql

case "$1" in
    "shell")
        exec bash -i
        ;;
    *)

    wait_pgsql

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
