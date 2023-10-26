#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/swhutils.sh

setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;

    *)
      exec python /src/alter_companion.py "$@"
      ;;
esac
