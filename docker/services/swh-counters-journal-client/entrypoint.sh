#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Starting swh-counters-journal client"
      exec wait-for-it kafka:9092 -s --timeout=0 -- \
          swh --log-level DEBUG counters --config-file /etc/softwareheritage/counters/journal_client.yml journal-client
      ;;
esac
