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

echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
cat > ~/.pg_service.conf <<EOF
[swh-scheduler]
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
    "swh-scheduler")
        exec $@
        ;;
    *)
        echo Waiting for postgresql to start
        until psql service=swh-scheduler -c "select 1" 2>&1 > /dev/null; do sleep 0.1; done

        echo Setup the swh-scheduler API database
        PGPASSWORD=${POSTGRES_PASSWORD} swh-db-init scheduler \
                  --db-name ${POSTGRES_DB}

        echo Starting the swh-scheduler API server
        exec python -m swh.scheduler.api.server /scheduler.yml
esac
