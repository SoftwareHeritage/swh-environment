#!/bin/bash

set -ex

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

source /srv/softwareheritage/utils/pgsql.sh
setup_pgsql

source /srv/softwareheritage/utils/swhutils.sh

if [ "$1" = 'shell' ] ; then
    shift
    if (( $# == 0)); then
        exec bash -i
    else
        "$@"
    fi
else

    if [ ! -z "$MEMCACHED" ]; then
       echo "Starting memcached"
       memcached&
    fi

    wait_pgsql

    echo "Migrating db"
    django-admin migrate --settings=${DJANGO_SETTINGS_MODULE}

    swh-deposit admin user exists test || \
        swh-deposit admin user create \
                    --username test \
                    --password test \
                    --provider-url https://softwareheritage.org \
                    --domain softwareheritage.org

    swh_start_django
fi
