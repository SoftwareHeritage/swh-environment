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

source /srv/softwareheritage/utils/pgsql.sh

setup_pgsql

case "$1" in
    "shell")
        exec bash -i
        ;;
    "worker")
        echo Starting the swh-vault Celery worker for
        exec python -m celery worker \
                    --app=swh.scheduler.celery_backend.config.app \
                    --pool=prefork --events \
                    --concurrency=${CONCURRENCY:-1} \
                    --maxtasksperchild=${MAX_TASKS_PER_CHILD:-10} \
                    -Ofair --loglevel=${LOGLEVEL:-INFO} --without-gossip \
                    --without-mingle --without-heartbeat \
                    --hostname "vault@%h"
        ;;
    "server")
        # ensure the pathslicing root dir for the cache exists
        mkdir -p /srv/softwareheritage/vault

        wait_pgsql

        echo Setup the swh-vault API database
        PGPASSWORD=${POSTGRES_PASSWORD} swh-db-init vault \
                  --db-name ${POSTGRES_DB}

        echo Starting the swh-vault API server
        exec swh-vault -C ${SWH_CONFIG_FILENAME}
esac
