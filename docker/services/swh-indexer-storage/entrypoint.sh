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
    *)

    wait_pgsql ${POSTGRES_DB}

    echo Database setup
    echo Creating extensions...
    swh db init-admin --db-name ${POSTGRES_DB} indexer

    echo Initializing the database...
    swh db init --db-name postgresql:///?service=${POSTGRES_DB} indexer

    echo Starting the swh-indexer-storage API server
    exec gunicorn --bind 0.0.0.0:5007 \
         --reload \
         --threads 2 \
         --workers 2 \
         --log-level DEBUG \
         --timeout 3600 \
         --config 'python:swh.core.api.gunicorn_config' \
         'swh.indexer.storage.api.server:make_app_from_configfile()'
    ;;
esac
