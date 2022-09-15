#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo Starting the swh-search API server
      if grep -q elasticsearch $SWH_CONFIG_FILENAME;
      then
        wait-for-it elasticsearch:9200 -s --timeout=0
        echo "Waiting for ElasticSearch cluster to be up"
        cat << EOF | python3
import elasticsearch
es = elasticsearch.Elasticsearch(['elasticsearch:9200'])
es.cluster.health(wait_for_status='yellow')
EOF
        echo "ElasticSearch cluster is up"
      fi
      swh search -C $SWH_CONFIG_FILENAME initialize
      exec gunicorn --bind 0.0.0.0:5010 \
           --reload \
           --threads 4 \
           --workers 2 \
           --log-level DEBUG \
           --timeout 3600 \
           --config 'python:swh.core.api.gunicorn_config' \
           'swh.search.api.server:make_app_from_configfile()'
      ;;
esac
