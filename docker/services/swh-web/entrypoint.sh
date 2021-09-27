#!/bin/bash

set -e

source /srv/softwareheritage/utils/pgsql.sh
setup_pgsql

# when overriding swh-web sources only
if [[ -d /src/swh-web ]] ; then
    echo "Install and compile swh-web static assets"
    pushd /src/swh-web
    yarn install --frozen-lockfile
    # execute webpack-dev-server in background
    yarn start-dev&
    popd
fi

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

case "$1" in
    "shell")
        exec bash -i
        ;;
     *)
        wait_pgsql

        echo "Migrating db using ${DJANGO_SETTINGS_MODULE}"
        django-admin migrate --settings=${DJANGO_SETTINGS_MODULE}

        echo "Creating Django test users"
        SWH_WEB_SRC_DIR=$(python3 -c "import os; from swh import web; print(os.path.dirname(web.__file__))")
        for create_user_script in $SWH_WEB_SRC_DIR/tests/create_test_*
        do
            cat $create_user_script | python3 -m swh.web.manage shell
        done

        echo "Start periodic save code now refresh statuses routine (in background)"
        (
            while true
            do
                (date && django-admin refresh_savecodenow_statuses \
                    --settings=${DJANGO_SETTINGS_MODULE} 2>&1) >> /tmp/refresh-statuses.log
                sleep 15
            done
        ) &
        disown

        echo "starting the swh-web server"
        if [[ -d /src/swh-web ]] ; then
            # run django development server when overriding swh-web sources
            exec django-admin runserver --nostatic --settings=${DJANGO_SETTINGS_MODULE} 0.0.0.0:5004
        else
            # run gunicorn workers as in production otherwise
            exec gunicorn --bind 0.0.0.0:5004 \
                --threads 2 \
                --workers 2 \
                --timeout 3600 \
                --access-logfile '-' \
                --config 'python:swh.web.gunicorn_config' \
                'django.core.wsgi:get_wsgi_application()'
        fi
esac
