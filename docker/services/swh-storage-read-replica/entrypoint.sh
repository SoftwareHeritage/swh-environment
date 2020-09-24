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
      wait_pgsql template1

      echo Database setup
      if ! check_pgsql_db_created; then
          echo Creating database and extensions...
          swh db create --db-name ${POSTGRES_DB} storage
      fi
      echo Initializing the database...
      swh db init --db-name ${POSTGRES_DB} --flavor read_replica storage

      wait_pgsql ${POSTGRES_DB_SRC} ${PGHOST_SRC}

      has_publication=$(\
        psql service=${POSTGRES_DB_SRC} \
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
          psql service=${POSTGRES_DB_SRC} \
               -v ON_ERROR_STOP=1 \
               -c "$replication_contents"
      fi

      has_subscription=$(\
        psql service=${POSTGRES_DB_SRC} \
          --quiet --no-psqlrc --no-align --tuples-only -v ON_ERROR_STOP=1 \
          -c "select count(*) from pg_subscription where subname='softwareheritage_replica';" \
      )

      if [ $has_subscription -ge 1 ]; then
          echo "Subscription found on replica database"
      else
          echo "Adding subscription to replica database"
          psql service=${POSTGRES_DB} -c "CREATE SUBSCRIPTION softwareheritage_replica CONNECTION 'host=${PGHOST_SRC} user=${PGUSER_SRC} dbname=${POSTGRES_DB_SRC} password=${POSTGRES_PASSWORD_SRC}' PUBLICATION softwareheritage;"
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
