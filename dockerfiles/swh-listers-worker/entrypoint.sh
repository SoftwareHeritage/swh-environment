#!/bin/bash

set -e
export PATH=${HOME}/.local/bin:${PATH}

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pushd $srcrepo
        echo "WARNING: $srcrepo wil NOT be pip installed in dev mode"
        echo "         due to permission limitations."
        pip install --user .
        popd
    done
fi

echo Installed Python packages:
pip list

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

chmod 0600 ~/.pgpass


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
            python -m swh.lister.cli \
                   --db-url postgres://${PGUSER}@${PGHOST}/${POSTGRES_DB} \
                   all
        fi

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
