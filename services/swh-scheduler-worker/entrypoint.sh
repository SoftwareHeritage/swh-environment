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

source /swh-utils/pgsql.sh

setup_pgsql

case "$1" in
    "shell")
        exec bash -i
        ;;
    *)
        wait_pgsql

        echo "Starting the swh-scheduler $1"
        exec wait-for-it amqp:5672 -s --timeout=0 -- swh-scheduler --log-level ${LOGLEVEL} -C /scheduler.yml $@
        ;;
esac
