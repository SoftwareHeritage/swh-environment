#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
        exec bash -i
        ;;
     *)
        echo "Migrating db using ${DJANGO_SETTINGS_MODULE}"
        django-admin migrate --settings=${DJANGO_SETTINGS_MODULE}

        echo "Creating admin user"
        echo "from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser('admin', 'admin@swh-web.org', 'admin')" | python3 -m swh.web.manage shell || true

        echo "starting the swh-web server"
        exec gunicorn --bind 0.0.0.0:5004 \
             --timeout 3600 \
             swh.web.wsgi
esac
