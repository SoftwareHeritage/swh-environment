#!/bin/bash

swh_start_rpc() {
    service=$1
    shift

    echo Starting the swh-${service} API server
    exec gunicorn --bind 0.0.0.0:${RPC_PORT:-5000} \
         --reload \
         --log-level ${LOG_LEVEL:-INFO} \
         --access-logfile /dev/stdout \
         --access-logformat "%(t)s %(r)s %(s)s %(b)s %(M)s" \
         --threads ${GUNICORN_THREADS:-2} \
         --workers ${GUNICORN_WORKERS:-2} \
         --timeout ${GUNICORN_TIMEOUT:-3600} \
         --config 'python:swh.core.api.gunicorn_config' \
         "swh.${service}.api.server:make_app_from_configfile()"

}

swh_start_django() {
  echo "starting the django server..."
  mode=${1:-wsgi}
  if [ "x$mode" == "xdev" ] ; then
      echo "... in dev mode (warning, this does not honor the SCRIPT_NAME env var)"
      # run django development server when overriding swh-web sources
      exec django-admin runserver \
           --nostatic \
           --settings=${DJANGO_SETTINGS_MODULE} \
           0.0.0.0:${RPC_PORT:-5004}
  else
      echo "... using gunicorn on ${RPC_PORT:-5004}"
      # run gunicorn workers as in production otherwise
      exec gunicorn --bind 0.0.0.0:${RPC_PORT:-5004} \
           --reload \
           --log-level ${LOG_LEVEL:-INFO} \
           --access-logfile /dev/stdout \
           --access-logformat "%(t)s %(r)s %(s)s %(b)s %(M)s" \
           --threads ${GUNICORN_THREADS:-2} \
           --workers ${GUNICORN_WORKERS:-2} \
           --timeout ${GUNICORN_TIMEOUT:-3600} \
           --config 'python:swh.web.gunicorn_config' \
           'django.core.wsgi:get_wsgi_application()'
  fi
}
