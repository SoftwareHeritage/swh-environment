#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pushd $srcrepo
        echo "WARNING: $srcrepo wil NOT be pip installed in dev mode"
        echo "         due to permission limitations."
        pip install --user .
        popd
    done
fi

export POSTGRES_DB=swh-lister-${SWH_WORKER_INSTANCE}

echo "${PGHOST}:5432:postgres:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" >> ~/.pgpass
cat > ~/.pg_service.conf <<EOF
[swh]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

chmod 0400 ~/.pgpass

mkdir -p ~/.config/swh/worker

cat > ~/.config/swh/worker/${SWH_WORKER_INSTANCE}.ini <<EOF
[main]
task_broker = amqp://guest@amqp//
task_modules = swh.lister.${SWH_WORKER_INSTANCE}.tasks
task_queues = swh_lister_${SWH_WORKER_INSTANCE}
task_soft_time_limit = 0
EOF

ln -s ~/.config/swh/lister.yml ~/.config/swh/lister-${SWH_WORKER_INSTANCE}.yml


case "$1" in
    "shell")
        exec bash -i
        ;;
    *)
        echo Setup ${POSTGRES_DB} database for ${SWH_WORKER_INSTANCE}

        if psql -lqt | cut -d \| -f 1 | grep -qw ${POSTGRES_DB}; then
            echo Database already exists, nothing to do
        else
            echo Creating database
            createdb ${POSTGRES_DB}
            echo Initialize database
            python -m swh.lister.cli --create-tables --with-data \
                   --db-url postgres://${PGUSER}@${PGHOST}/${POSTGRES_DB} \
                   --lister ${SWH_WORKER_INSTANCE}
        fi
        echo Starting the swh-lister Celery worker for ${SWH_WORKER_INSTANCE}
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
