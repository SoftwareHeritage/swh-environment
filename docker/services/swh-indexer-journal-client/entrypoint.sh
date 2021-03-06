#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Starting swh-indexer-journal client"
      wait-for-it kafka:9092 -s --timeout=0 -- \
        swh --log-level DEBUG indexer --config-file /etc/softwareheritage/indexer/journal_client.yml journal-client
      ;;
esac

