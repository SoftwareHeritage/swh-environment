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

if [ "$1" = 'shell' ] ; then
	exec bash -i
else
	echo Starting the swh-objstorage API server
	exec python -m swh.objstorage.api.server /objstorage.yml
fi
