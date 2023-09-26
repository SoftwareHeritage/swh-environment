#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

if [ "$STORAGE_BACKEND" != "postgresql" ]; then
    echo "Unsupported STORAGE_BACKEND ${STORAGE_BACKEND}; Only postgresql is supported."
    exit 255
fi

source /srv/softwareheritage/utils/pgsql.sh
setup_pgsql

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      wait_pgsql

      echo Database setup
      echo " step 1: init-admin"
      swh db init-admin --dbname postgresql:///?service=${NAME} storage
      echo " step 2: init"
	  swh db init --flavor ${DB_FLAVOR:-default} storage
      echo " step 3: upgrade"
      python3 -m swh db upgrade --non-interactive storage

      has_publication=$(\
        psql service=${REPLICA_SRC} \
          --quiet --no-psqlrc --no-align --tuples-only -v ON_ERROR_STOP=1 \
          -c "select count(*) from pg_publication where pubname='softwareheritage';" \
      )

      if [ $has_publication -ge 1 ]; then
          echo "Publication found on source database"
      else
          echo "Adding publication to source database"
          replication_contents=$(python -c '
from importlib_metadata import files

for file in files("swh.storage"):
    if str(file).endswith("sql/logical_replication/replication_source.sql"):
        print(file.read_text())
')
          psql service=${REPLICA_SRC} \
               -v ON_ERROR_STOP=1 \
               -c "$replication_contents"
      fi

      has_subscription=$(\
        psql service=${NAME} \
          --quiet --no-psqlrc --no-align --tuples-only -v ON_ERROR_STOP=1 \
          -c "select count(*) from pg_subscription where subname='softwareheritage_replica';" \
      )

      if [ $has_subscription -ge 1 ]; then
          echo "Subscription found on replica database"
      else
          echo "Adding subscription to replica database"
          psql service=${NAME} -c "CREATE SUBSCRIPTION softwareheritage_replica CONNECTION '${REPLICA_SRC_DSN}' PUBLICATION softwareheritage;"
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
