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
        echo Waiting for RabbitMQ to start
        wait-for-it amqp:5672 -s --timeout=0

        wait_pgsql

        wait-for-it swh-idx-storage:5007 -s --timeout=0

        echo Starting swh-indexer Celery-based worker
        exec python -m celery \
             --app=swh.scheduler.celery_backend.config.app \
             worker \
             --pool=prefork --events \
             --concurrency=${CONCURRENCY} \
             --max-tasks-per-child=${MAX_TASKS_PER_CHILD} \
             -Ofair --loglevel=${LOGLEVEL} \
             --hostname "${SWH_WORKER_INSTANCE}@%h"
    ;;
esac
