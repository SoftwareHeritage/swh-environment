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

source /srv/softwareheritage/utils/pgsql.sh

setup_pgsql

if [ "$1" = 'shell' ] ; then
    exec bash -i
else

    wait_pgsql

    echo "Migrating db"
    django-admin migrate --settings=swh.deposit.settings.production

    echo "starting swh-deposit server"
    exec gunicorn --bind 0.0.0.0:5006 \
                  --reload \
                  --log-level DEBUG \
                  --timeout 3600 \
                  swh.deposit.wsgi
fi
