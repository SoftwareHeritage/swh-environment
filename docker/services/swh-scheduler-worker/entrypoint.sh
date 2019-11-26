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

        echo "Starting the swh-scheduler $1"
        exec wait-for-it amqp:5672 -s --timeout=0 -- swh --log-level ${LOGLEVEL} scheduler -C /scheduler.yml $@
        ;;
esac
