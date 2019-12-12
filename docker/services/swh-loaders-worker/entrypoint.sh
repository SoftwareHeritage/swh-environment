#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
        exec bash -i
        ;;
    *)
        echo Waiting for RabbitMQ to start
        wait-for-it amqp:5672 -s --timeout=0

        echo Register task types in scheduler database
        swh scheduler -C ${SWH_CONFIG_FILENAME} task-type register

        echo Starting the swh-loader Celery worker for ${SWH_WORKER_INSTANCE}
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
