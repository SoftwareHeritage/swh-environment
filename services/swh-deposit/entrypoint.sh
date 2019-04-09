#!/bin/bash

set -ex

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

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
