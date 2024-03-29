#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
		shift
		echo "Running command $@"
        exec bash -i "$@"
        ;;
	"swh")
		shift
        wait-for-it swh-storage:5002 -s --timeout=0
        echo "Running swh command $@"
        exec swh $@
		;;
    *)
        echo Waiting for RabbitMQ to start
        wait-for-it amqp:5672 -s --timeout=0

        echo Register task types in scheduler database
        wait-for-it swh-scheduler:5008 -s --timeout=0
        swh scheduler --url ${SWH_SCHEDULER_INSTANCE} task-type register

        echo Starting the swh Celery worker for ${SWH_WORKER_INSTANCE}
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
