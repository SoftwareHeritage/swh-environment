#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/swhutils.sh

setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
	"replayer")
	  shift
      wait-for-it swh-objstorage:5003
      wait-for-it swh-objstorage-mirror:5003
      echo "Starting the SWH mirror content replayer"
      exec swh --log-level ${LOG_LEVEL:-WARNING} \
           objstorage replay $@
      ;;
	"rpc")
	  shift
	  swh_start_rpc objstorage
	  ;;
esac
