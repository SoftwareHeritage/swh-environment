#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

DATADIR=/srv/softwareheritage/graph

update_graph() {
  mkdir -p $DATADIR/
  rm -rf $DATADIR/*  # cleanup results from previous runs
  mkdir -p $DATADIR/g/edges/
  echo "Exporting edges and nodes"
  swh dataset -C $SWH_CONFIG_FILENAME graph export $DATADIR/g --processes=8 --formats=orc
  echo "Sorting edges and nodes"
  swh dataset graph sort $DATADIR/g/edges
  echo "Compressing graph"
  swh graph compress --input-dataset $DATADIR/g/orc/ --output-directory $DATADIR/compressed
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
      exec swh \
           --log-level DEBUG \
           graph \
           grpc-serve \
           --port 5009 \
           --graph $DATADIR/compressed/graph
      ;;
esac
