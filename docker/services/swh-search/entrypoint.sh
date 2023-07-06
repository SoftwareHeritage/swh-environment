#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      nb_workers=2
      echo Extracting swh-search backend from config file
      backend=$(python3 -c "
import yaml
from yaml.loader import SafeLoader
with open('$SWH_CONFIG_FILENAME', 'r') as f:
  print(yaml.load(f, Loader=SafeLoader)['search']['cls'])
")

      if [[ "$backend" == "elasticsearch" ]];
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

      if [[ "$backend" == "memory" ]];
      then
        # use a single worker when using a memory backend for swh-search
        # as each worker has its own search instance otherwise
        nb_workers=1
      fi

      echo Starting swh-search API server
      swh search -C $SWH_CONFIG_FILENAME initialize
      exec gunicorn --bind 0.0.0.0:5010 \
           --reload \
           --threads 4 \
           --workers $nb_workers \
           --log-level DEBUG \
           --timeout 3600 \
           --config 'python:swh.core.api.gunicorn_config' \
           'swh.search.api.server:make_app_from_configfile()'
      ;;
esac
