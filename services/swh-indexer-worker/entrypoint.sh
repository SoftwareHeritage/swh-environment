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

case "$1" in
    "shell")
        exec bash -i
        ;;
    *)
        echo Waiting for RabbitMQ to start
        wait-for-it amqp:5672 -s --timeout=0

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
