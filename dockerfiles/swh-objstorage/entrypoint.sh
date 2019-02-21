#!/bin/bash

set -e

echo Step 1
if [[ -d /src ]] ; then
	echo Yes
	for srcrepo in /src/swh-* ; do
		echo installing $srcrepo
		pushd $srcrepo
		pip install -e .
		popd
	done
fi

echo Installed Python packages:
pip list

if [ "$1" = 'shell' ] ; then
	exec bash -i
else
	echo Starting the swh-objstorage API server
        exec gunicorn --bind 0.0.0.0:5003 \
           --worker-class aiohttp.worker.GunicornWebWorker \
           --log-level DEBUG \
           --reload \
           swh.objstorage.api.wsgi

fi
