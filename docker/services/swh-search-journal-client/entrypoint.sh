#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Starting swh-search-journal client"
      exec wait-for-it -s kafka:9092 -s --timeout=0 -- \
          wait-for-it -s swh-search:5010 -s --timeout=0 -- \
          swh --log-level DEBUG search --config-file /etc/softwareheritage/search/journal_client.yml journal-client objects
      ;;
esac
