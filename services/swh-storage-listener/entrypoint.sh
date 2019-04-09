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

      echo "Starting swh-storage-listener"
      exec wait-for-it kafka:9092 -s --timeout=0 -- python3 -m swh.storage.listener
      ;;
esac
