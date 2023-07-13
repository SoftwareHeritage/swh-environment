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
      wait_pgsql template1

      echo Database setup
      if ! check_pgsql_db_created; then
          echo Creating database and extensions...
          swh db create --db-name ${POSTGRES_DB} storage
      fi
      echo Initializing the database...
      swh db init --db-name postgresql:///?service=${POSTGRES_DB} --flavor mirror storage

      echo Starting the swh-storage Kafka storage replayer
      exec swh storage replay
      ;;
esac
