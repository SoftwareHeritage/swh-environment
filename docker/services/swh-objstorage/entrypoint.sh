#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

echo Installed Python packages:
pip list

if [ "$1" = 'shell' ] ; then
    exec bash -i
else
    echo Starting the swh-objstorage API server
  exec gunicorn --bind 0.0.0.0:5003 \
       --worker-class aiohttp.worker.GunicornWebWorker \
       --log-level DEBUG \
       --threads 4 \
       --workers 2 \
       --reload \
       --timeout 3600 \
       --config 'python:swh.core.api.gunicorn_config' \
       'swh.objstorage.api.server:make_app_from_configfile()'

fi
