#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        echo installing $srcrepo
        pip install -e .
        popd
    done
fi

if [ "$1" = 'shell' ] ; then
    exec bash -i
else
    echo "starting the swh-web server"
    exec python3 -m swh.web.manage runserver --nostatic 0.0.0.0:5004
    #exec gunicorn3 -b 0.0.0.0:5004 swh.web.wsgi
fi
