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
      PGPASSWORD=${POSTGRES_PASSWORD} swh db-init \
          --db-name ${POSTGRES_DB} storage

      echo Starting the swh-storage Kafka storage replayer
      exec swh journal replay \
		   --broker kafka \
		   --prefix swh.journal.objects \
		   --consumer-id swh.storage.replica
      ;;
esac
