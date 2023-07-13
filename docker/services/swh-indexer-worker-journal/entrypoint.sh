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
        echo Waiting for Kafka to start
        wait-for-it kafka:9092 -s --timeout=0

        wait_pgsql

        wait-for-it swh-idx-storage:5007 -s --timeout=0

        echo Starting swh-indexer journal-based worker
        swh --log-level ${LOGLEVEL} indexer --config-file /indexer.yml journal-client '*'
    ;;
esac
