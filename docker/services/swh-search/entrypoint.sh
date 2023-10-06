#!/bin/bash

set -e

source /srv/softwareheritage/utils/pgsql.sh
source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/swhutils.sh

setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;

    "rpc")
      shift
      GUNICORN_WORKERS=${GUNICORN_WORKERS:-2}
      echo Extracting swh-search backend from config file
      backend=$(yq -r .search.cls $SWH_CONFIG_FILENAME)

      case "$backend" in
          "elasticsearch")
              wait-for-it elasticsearch:9200 -s --timeout=0
              echo "Waiting for ElasticSearch cluster to be up"
              cat << EOF | python3
import elasticsearch
es = elasticsearch.Elasticsearch(['elasticsearch:9200'])
es.cluster.health(wait_for_status='yellow')
EOF
              echo "ElasticSearch cluster is up"
              ;;

          "memory")
              # use a single worker when using a memory backend for swh-search
              # as each worker has its own search instance otherwise
              GUNICORN_WORKERS=1
              ;;
      esac

      swh_start_rpc search
      ;;

    "journal-client")
      echo "Starting swh-search-journal client"
      exec wait-for-it -s kafka:9092 -s --timeout=0 -- \
          wait-for-it -s swh-search:5010 -s --timeout=0 -- \
          swh --log-level DEBUG search \
              --config-file $SWH_CONFIG_FILENAME \
              journal-client objects
      ;;

esac
