#!/bin/bash

set -ex

if [[ -d /src ]] ; then
    pwd
    for src_repo in /src/swh-* ; do
        pushd $src_repo
        echo "Installing ${src_repo}"
        pip install -e .
        popd
    done
fi

echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
cat > ~/.pg_service.conf <<EOF
[swh-deposit]
host=${PGHOST}
port=5432
dbname=${POSTGRES_DB}
user=${PGUSER}
EOF

chmod 0600 ~/.pgpass

if [ "$1" = 'shell' ] ; then
    exec bash -i
else
    echo "Waiting for postgresql to start"
    until psql postgresql:///?service=swh-deposit -c "select 1" > /dev/null 2> /dev/null; do sleep 0.1; done

    echo "Migrating db"
    django-admin migrate --settings=swh.deposit.settings.production

    echo "starting swh-deposit server"
    exec gunicorn --bind 0.0.0.0:5006 \
                  --reload \
                  --log-level DEBUG \
                  --timeout 3600 \
                  swh.deposit.wsgi
fi
