#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/pgsql.sh

setup_pgsql
setup_pip


case "$1" in
    "shell")
        shift
        if (( $# == 0)); then
            exec bash -i
        else
            "$@"
        fi
        ;;
    "update-metrics")
        wait-for-it swh-scheduler:5008 -s --timeout=0

        echo "Start periodic scheduler metrics update routine (in background)"
        exec sh -c 'trap exit TERM INT; while :; do
        (date && swh scheduler origin update-metrics)
        sleep 60 &
        wait ${!}
        done'
        ;;
    *)
        wait_pgsql

        echo swh-scheduler database setup

        echo " step 1: Creating extensions..."
        swh db init-admin --db-name postgresql:///?service=${NAME} scheduler

        echo " step 2: Initializing the database..."
        swh db init scheduler

        echo " step 3: upgrade"
        swh db upgrade --non-interactive scheduler

        echo Starting the swh-scheduler API server
        exec gunicorn --bind 0.0.0.0:5008 \
            --log-level DEBUG \
            --threads 2 \
            --workers 2 \
            --reload \
            --timeout 3600 \
            --config 'python:swh.core.api.gunicorn_config' \
            'swh.scheduler.api.server:make_app_from_configfile()'
esac
