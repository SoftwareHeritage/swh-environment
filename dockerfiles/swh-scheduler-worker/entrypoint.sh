#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pushd $srcrepo
        pip install -e .
        popd
    done
fi

echo '#################### Warning #####################'
echo '# Install kombu from sources as a workaround for #'
echo '# https://forge.softwareheritage.org/T1491       #'
echo '# TODO: Remove this ASAP                         #'
echo '##################################################'
pip install git+https://github.com/celery/kombu.git

echo Installed Python packages:
pip list

echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
cat > ~/.pg_service.conf <<EOF
[swh-scheduler]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

chmod 0600 ~/.pgpass

case "$1" in
    "shell")
        exec bash -i
        ;;
    *)
		echo Starting the swh-scheduler $1
		exec swh-scheduler --log-level ${LOGLEVEL} -C /scheduler.yml $@
        ;;
esac
