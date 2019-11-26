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
    *)
        wait_pgsql

        echo Setup ${POSTGRES_DB} database for ${SWH_WORKER_INSTANCE}
        if psql -lqt | cut -d \| -f 1 | grep -qw ${POSTGRES_DB}; then
            echo Database already exists, nothing to do
        else
            echo Creating database
            createdb ${POSTGRES_DB}
        fi

        echo Initialize database
        swh lister -C ${SWH_CONFIG_FILENAME} db-init

        echo Register task types in scheduler database
        swh scheduler -C ${SWH_CONFIG_FILENAME} task-type register

        echo Waiting for RabbitMQ to start
        wait-for-it amqp:5672 -s --timeout=0

        echo Starting the swh-lister Celery worker for ${SWH_WORKER_INSTANCE}
        exec python -m celery worker \
                    --app=swh.scheduler.celery_backend.config.app \
                    --pool=prefork --events \
                    --concurrency=${CONCURRENCY} \
                    --maxtasksperchild=${MAX_TASKS_PER_CHILD} \
                    -Ofair --loglevel=${LOGLEVEL} --without-gossip \
                    --without-mingle \
                    --heartbeat-interval 10 \
                    --hostname "${SWH_WORKER_INSTANCE}@%h"
        ;;
esac
