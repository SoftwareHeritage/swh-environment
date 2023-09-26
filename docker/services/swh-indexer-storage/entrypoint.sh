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

    wait_pgsql

	echo "============================"
	cat $SWH_CONFIG_FILENAME
	echo "============================"
    echo Database setup
    echo " step 1: Creating extensions..."
    swh db init-admin --dbname postgresql:///?service=${NAME} indexer

    echo " step 2: Initializing the database..."
    swh db init indexer

    echo " step 3: upgrade"
    python3 -m swh db upgrade --non-interactive indexer

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
