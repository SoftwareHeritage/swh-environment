#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

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
        PGPASSWORD=${POSTGRES_PASSWORD} swh db-init \
            --db-name ${POSTGRES_DB} scheduler

        echo Starting the swh-scheduler API server
        exec gunicorn --bind 0.0.0.0:5008 \
             --log-level DEBUG \
             --threads 2 \
             --workers 2 \
             --reload \
             --timeout 3600 \
             'swh.scheduler.api.server:make_app_from_configfile()'

esac
