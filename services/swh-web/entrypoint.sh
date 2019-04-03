#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pushd $srcrepo
        echo installing $srcrepo
        pip install -e .
        popd
    done
fi

echo Installed Python packages:
pip list

case "$1" in
    "shell")
        exec bash -i
        ;;
     *)
        echo "Migrating db"
        django-admin migrate --settings=${DJANGO_SETTINGS_MODULE}

        echo "Creating admin user"
        echo "from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser('admin', 'admin@swh-web.org', 'admin')" | python3 -m swh.web.manage shell

        echo "starting the swh-web server"
        exec gunicorn --bind 0.0.0.0:5004 \
             --timeout 3600 \
             swh.web.wsgi
esac
