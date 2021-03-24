#!/bin/bash

set -ex

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

source /srv/softwareheritage/utils/pgsql.sh
setup_pgsql

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

    echo "starting swh-deposit server"
    exec gunicorn --bind 0.0.0.0:5006 \
                  --reload \
                  --threads 2 \
                  --workers 2 \
                  --log-level DEBUG \
                  --timeout 3600 \
                  --config 'python:swh.core.api.gunicorn_config' \
                  'django.core.wsgi:get_wsgi_application()'
fi
