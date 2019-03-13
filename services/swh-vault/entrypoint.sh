#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pushd $srcrepo
        pip install -e .
        popd
    done
fi

echo Installed Python packages:
pip list

if [[ -n $PGHOST ]]; then
    echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
    cat > ~/.pg_service.conf <<EOF
[swh-vault]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

    chmod 0600 ~/.pgpass
fi

case "$1" in
    "shell")
        exec bash -i
        ;;
    "worker")
        echo Starting the swh-vault Celery worker for
        exec python -m celery worker \
                    --app=swh.scheduler.celery_backend.config.app \
                    --pool=prefork --events \
                    --concurrency=${CONCURRENCY:-1} \
                    --maxtasksperchild=${MAX_TASKS_PER_CHILD:-10} \
                    -Ofair --loglevel=${LOGLEVEL:-INFO} --without-gossip \
                    --without-mingle --without-heartbeat \
                    --hostname "vault@%h"
        ;;
    "server")
        # ensure the pathslicing root dir for the cache exists
        mkdir -p /srv/softwareheritage/vault

        echo Waiting for postgresql to start
        wait-for-it swh-vault-db:5432 -s --timeout=0

        echo Setup the swh-vault API database
        PGPASSWORD=${POSTGRES_PASSWORD} swh-db-init vault \
                  --db-name ${POSTGRES_DB}

        echo Starting the swh-vault API server
        exec swh-vault -C /vault-api.yml
esac
