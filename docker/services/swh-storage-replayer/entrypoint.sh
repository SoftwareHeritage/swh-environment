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

      echo Database setup

      echo " step 1: init-admin"
      swh db init-admin --dbname postgresql:///?service=${NAME} storage

      echo " step 2: Initializing the database..."
      swh db init --flavor ${DB_FLAVOR:-default} storage

      echo " step 3: upgrade"
      python3 -m swh db upgrade --non-interactive storage

      echo Starting the swh-storage Kafka storage replayer
      exec swh --log-level ${LOG_LEVEL:-WARNING} storage replay
      ;;
esac
