# usage: . pythonpath
#
# source this file as above (do not execute it) to set the PYTHONPATH
# environment variable to the list of directories corresponding to the
# repositories known to mr

export PYTHONPATH=`bin/list-repos --absolute | paste -d: -s`
