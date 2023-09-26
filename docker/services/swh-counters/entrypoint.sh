#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/swhutils.sh

setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;

    "rpc")
	  shift
      echo "Starting the swh-counters API server"
      wait-for-it redis:6379 -s --timeout=0
	  swh_start_rpc counters
	  ;;

	"journal-client")
	  shift
	  echo "Starting swh-counters-journal client"
      exec wait-for-it kafka:9092 -s --timeout=0 -- \
           swh --log-level DEBUG counters \
		   --config-file $SWH_CONFIG_FILENAME \
		   journal-client
      ;;
esac
