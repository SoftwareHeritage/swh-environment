#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

DATADIR=/srv/softwareheritage/graph

update_graph() {
  mkdir -p $DATADIR/
  rm -rf $DATADIR/*  # cleanup results from previous runs
  mkdir $DATADIR/g/
  echo "Exporting edges and nodes"
  swh dataset -C $SWH_CONFIG_FILENAME graph export $DATADIR/g --processes=8 --formats=edges
  echo "Sorting edges and nodes"
  swh dataset graph sort $DATADIR/g/edges
  echo "Compressing graph"
  swh graph compress --graph $DATADIR/g/edges/graph --outdir $DATADIR/compressed
}

case "$1" in
    "shell")
      exec bash -i
      ;;
    "update")
      update_graph
      ;;
    *)
      if [[ ! -d $DATADIR/compressed ]] ; then
        # Generate the graph if it wasn't already
        update_graph
      fi
      echo "Starting the swh-graph API server"
      exec gunicorn --bind 0.0.0.0:5009 \
           --worker-class aiohttp.worker.GunicornWebWorker \
           --reload \
           --threads 4 \
           --workers 2 \
           --log-level DEBUG \
           --timeout 3600 \
           --config 'python:swh.core.api.gunicorn_config' \
           'swh.graph.server.app:make_app_from_configfile()'
      ;;
esac
