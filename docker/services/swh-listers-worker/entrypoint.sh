#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
        exec bash -i
        ;;
    *)

        echo Register task types in scheduler database
        wait-for-it swh-scheduler:5008 -s --timeout=0
        swh scheduler -C ${SWH_CONFIG_FILENAME} task-type register

        echo Waiting for RabbitMQ to start
        wait-for-it amqp:5672 -s --timeout=0

        echo Starting the swh-lister Celery worker for ${SWH_WORKER_INSTANCE}
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
