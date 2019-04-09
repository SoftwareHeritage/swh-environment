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

      echo Setup the database
      PGPASSWORD=${POSTGRES_PASSWORD} swh-db-init storage \
          --db-name ${POSTGRES_DB}

      echo Starting the swh-storage API server
      exec gunicorn --bind 0.0.0.0:5002 \
           --reload \
           --log-level DEBUG \
           --timeout 3600 \
           swh.storage.api.wsgi
      ;;
esac
