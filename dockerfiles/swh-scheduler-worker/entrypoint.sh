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
cat > ~/.pg_service.conf <<EOF
[swh-scheduler]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

chmod 0400 ~/.pgpass

case "$1" in
    "shell")
        exec bash -i
        ;;
    "listener")
        echo Starting the swh-scheduler listener
        exec python -m swh.scheduler.celery_backend.listener
		;;
    "runner")
        echo Starting the swh-scheduler runner
        exec sh -c 'while true; do
            echo running pending tasks at `/bin/date`;
            python -m swh.scheduler.celery_backend.runner;
            sleep 10;
          done'  # beuark
		;;
	*)
		echo "Provide a command (shell|listener|runner)"
		exit 1
		;;
esac
