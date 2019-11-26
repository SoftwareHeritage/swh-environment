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

        echo Starting swh-indexer worker
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
