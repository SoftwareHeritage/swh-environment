#!/bin/bash

set -e

create_admin_script="
from django.contrib.auth import get_user_model;

username = 'admin';
password = 'admin';
email = 'admin@swh-web.org';

User = get_user_model();

if not User.objects.filter(username = username).exists():
    User.objects.create_superuser(username, email, password);
"

source /srv/softwareheritage/utils/pgsql.sh
setup_pgsql

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
        exec bash -i
        ;;
     *)
        echo "Starting memcached"
        memcached&

        wait_pgsql

        echo "Migrating db using ${DJANGO_SETTINGS_MODULE}"
        django-admin migrate --settings=${DJANGO_SETTINGS_MODULE}

        echo "Creating Django admin user"
        echo "$create_admin_script" | python3 -m swh.web.manage shell

        echo "starting the swh-web server"
        exec gunicorn --bind 0.0.0.0:5004 \
             --threads 2 \
             --workers 2 \
             --timeout 3600 \
             --access-logfile '-' \
             --config 'python:swh.web.gunicorn_config' \
             'django.core.wsgi:get_wsgi_application()'
esac
