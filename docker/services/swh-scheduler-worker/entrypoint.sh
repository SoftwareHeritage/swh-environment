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

        wait-for-it swh-scheduler:5008 -s --timeout=0
        wait-for-it amqp:5672 -s --timeout=0

        echo "Waiting for loader task types to be registered in scheduler db"
        until python3 -c "
from celery import Celery
app = Celery('swh', broker='amqp://guest:guest@amqp/')
assert any(worker_name.startswith('loader@')
           for worker_name in app.control.inspect().active())" 2>/dev/null
        do
            sleep 1
        done

        echo "Starting swh scheduler $1"
        exec swh --log-level ${LOGLEVEL} scheduler -C /scheduler.yml $@
        ;;
esac
