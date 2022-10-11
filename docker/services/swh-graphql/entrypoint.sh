#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo Starting the swh-graphql API server

      exec gunicorn --bind 0.0.0.0:5013 \
           --reload \
           --threads 4 \
           --workers 2 \
           --worker-class uvicorn.workers.UvicornWorker \
           --log-level DEBUG \
           --timeout 3600 \
           --config 'python:swh.core.api.gunicorn_config' \
           'swh.graphql.server:make_app_from_configfile()'
      ;;
esac
