#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
      pushd $srcrepo
      pip install -e .
      popd
    done
fi

echo Installed Python packages:
pip list

source /swh-utils/pgsql.sh

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

      echo Starting the swh-storage Kafka storage replayer
      exec swh-journal replay --broker kafka --prefix swh.journal.objects \
		   --consumer-id swh.storage.replica
      ;;
esac
