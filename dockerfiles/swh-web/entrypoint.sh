#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        echo installing $srcrepo
        pip install -e .
        popd
    done
fi

echo Installed Python packages:
pip list

if [ "$1" = 'shell' ] ; then
    exec bash -i
else
    echo "starting the swh-web server"
    # options:
    # --verbosity to have sensible output
    # --insecure to serve the static css/js
    # 0.0.0.0 so that we can actually reach the service.
    exec python3 -m swh.web.manage runserver \
         --verbosity 3 \
         --insecure \
         0.0.0.0:5004
fi
