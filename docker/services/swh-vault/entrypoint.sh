#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

source /srv/softwareheritage/utils/pgsql.sh
setup_pgsql

case "$1" in
    "shell")
        exec bash -i
        ;;
    "worker")
        echo Starting the swh-vault Celery worker
        exec python -m celery \
                    --app=swh.scheduler.celery_backend.config.app \
                    worker \
                    --pool=prefork --events \
                    --concurrency=${CONCURRENCY} \
                    --max-tasks-per-child=${MAX_TASKS_PER_CHILD} \
                    -Ofair --loglevel=${LOGLEVEL} \
                    --hostname "vault@%h"
        ;;
    "server")
        # ensure the pathslicing root dir for the cache exists
        mkdir -p /srv/softwareheritage/vault

        wait_pgsql template1

        echo swh-vault Database setup
        if ! check_pgsql_db_created; then
            echo Creating database and extensions...
            swh db create --db-name ${POSTGRES_DB} vault
        fi
        echo Initializing the database...
        swh db init --db-name ${POSTGRES_DB} vault

        echo Starting the swh-vault API server
        exec swh vault rpc-serve -C ${SWH_CONFIG_FILENAME}
esac
