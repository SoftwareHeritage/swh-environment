#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

if [ "$STORAGE_BACKEND" = "postgresql" ]; then
    source /srv/softwareheritage/utils/pgsql.sh
    setup_pgsql

elif [ "$STORAGE_BACKEND" = "cassandra" ]; then
    echo Waiting for Cassandra to start
    wait-for-it ${CASSANDRA_SEED}:9042 -s --timeout=0
    echo Creating keyspace
    cat << EOF | python3
from swh.storage.cassandra import create_keyspace
create_keyspace(['cassandra-seed'], 'swh')
EOF

fi

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      if [ "$STORAGE_BACKEND" = "postgresql" ]; then
          wait_pgsql ${POSTGRES_DB}

          echo Database setup

          echo Creating extensions...
          swh db init-admin --db-name ${POSTGRES_DB} storage

          echo Initializing the database...
          swh db init --db-name ${POSTGRES_DB} storage
      fi

      echo Starting the swh-storage API server
      exec gunicorn --bind 0.0.0.0:5002 \
           --reload \
           --threads 4 \
           --workers 2 \
           --log-level DEBUG \
           --timeout 3600 \
           --config 'python:swh.core.api.gunicorn_config' \
           'swh.storage.api.server:make_app_from_configfile()'
      ;;
esac
