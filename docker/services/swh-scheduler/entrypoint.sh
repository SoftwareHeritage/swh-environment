#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/pgsql.sh

setup_pgsql
setup_pip


if [ "$1" = 'shell' ] ; then
	shift
	if (( $# == 0)); then
		exec bash -i
	else
		"$@"
	fi
else
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
         --config 'python:swh.core.api.gunicorn_config' \
         'swh.scheduler.api.server:make_app_from_configfile()'
fi
