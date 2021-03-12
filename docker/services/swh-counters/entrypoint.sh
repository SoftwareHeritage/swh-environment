#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Starting the swh-counters API server"
      wait-for-it redis:6379 -s --timeout=0
      exec gunicorn --bind 0.0.0.0:5011 \
           --reload \
           --threads 4 \
           --workers 2 \
           --log-level DEBUG \
           --timeout 3600 \
           --config 'python:swh.core.api.gunicorn_config' \
           'swh.counters.api.server:make_app_from_configfile()'
      ;;
esac
