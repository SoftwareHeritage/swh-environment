#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pushd $srcrepo
        echo installing $srcrepo
        pip install -e .
        popd
    done
fi

echo Installed Python packages:
pip list

case "$1" in
    "shell")
        exec bash -i
        ;;
     *)
        echo "starting the swh-web server"
        exec gunicorn -b 0.0.0.0:5004 swh.web.wsgi
esac
