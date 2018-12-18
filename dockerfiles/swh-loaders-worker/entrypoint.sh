#!/bin/bash

set -e

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

mkdir -p ~/.config/swh/worker

cat > ~/.config/swh/worker/${SWH_WORKER_INSTANCE}.ini <<EOF
[main]
task_broker = amqp://guest@amqp//
task_modules = swh.loader.${SWH_WORKER_INSTANCE}.tasks
task_queues = swh_loader_${SWH_WORKER_INSTANCE}
task_soft_time_limit = 0
EOF

ln -s ~/.config/swh/loader.yml ~/.config/swh/loader-${SWH_WORKER_INSTANCE}.yml


case "$1" in
    "shell")
        exec bash -i
        ;;
    *)
        echo Starting the swh-loader Celery worker for ${SWH_WORKER_INSTANCE}
        exec python -m celery worker \
                    --app=swh.scheduler.celery_backend.config.app \
                    --pool=prefork --events \
                    --concurrency=${CONCURRENCY} \
                    --maxtasksperchild=${MAX_TASKS_PER_CHILD} \
                    -Ofair --loglevel=${LOGLEVEL} --without-gossip \
                    --without-mingle --without-heartbeat \
                    --hostname ${SWH_WORKER_INSTANCE}.${HOSTNAME}
        ;;
esac
