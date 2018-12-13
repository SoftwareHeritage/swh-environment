#!/bin/bash

set -e

if [[ -d /src ]] ; then
	for srcrepo in /src/swh-* ; do
		pushd $srcrepo
		pip install -e .
		popd
	done
fi

echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
chmod 0400 ~/.pgpass

case "$1" in
	"shell")
		exec bash -i
		;;
	"init")
		echo Setup the database
		swh-db-init storage --db-name ${POSTGRES_DB} --no-create True
		;;
	*)
		echo Starting the swh-storage API server
		exec python -m swh.storage.api.server /storage.yml
esac
