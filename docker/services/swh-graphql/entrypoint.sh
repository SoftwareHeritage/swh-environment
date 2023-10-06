#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/swhutils.sh

setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    "rpc")

        echo Starting the swh-graphql API server
        exec gunicorn --bind 0.0.0.0:${RPC_PORT:-5000} \
         --reload \
         --log-level ${LOG_LEVEL:-INFO} \
         --access-logfile /dev/stdout \
         --access-logformat "%(t)s %(r)s %(s)s %(b)s %(M)s" \
         --threads ${GUNICORN_THREADS:-2} \
         --workers ${GUNICORN_WORKERS:-2} \
         --timeout ${GUNICORN_TIMEOUT:-3600} \
         --config 'python:swh.core.api.gunicorn_config' \
         "swh.graphql.server:make_app_from_configfile()"
      ;;
esac
