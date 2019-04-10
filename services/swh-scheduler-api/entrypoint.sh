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

source /srv/softwareheritage/utils/pgsql.sh

setup_pgsql

case "$1" in
    "shell")
        exec bash -i
        ;;
    "swh-scheduler")
        exec $@
        ;;
    *)
        wait_pgsql

        echo Setup the swh-scheduler API database
        PGPASSWORD=${POSTGRES_PASSWORD} swh-db-init scheduler \
                  --db-name ${POSTGRES_DB}

        echo Starting the swh-scheduler API server
        exec gunicorn --bind 0.0.0.0:5008 \
             --log-level DEBUG \
             --reload \
             --timeout 3600 \
             swh.scheduler.api.wsgi

esac
