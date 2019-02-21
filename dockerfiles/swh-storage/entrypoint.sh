#!/bin/bash

set -e

if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
      pushd $srcrepo
      pip install -e .
      popd
    done
fi

echo Installed Python packages:
pip list

echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
cat > ~/.pg_service.conf <<EOF
[swh]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

chmod 0600 ~/.pgpass

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo Waiting for postgresql to start
      until psql postgresql:///?service=swh -c "select 1" > /dev/null 2> /dev/null; do sleep 0.1; done

      echo Setup the database
      PGPASSWORD=${POSTGRES_PASSWORD} swh-db-init storage \
          --db-name ${POSTGRES_DB}

      echo Starting the swh-storage API server
      exec gunicorn --bind 0.0.0.0:5002 \
           --reload \
           --log-level DEBUG \
           swh.storage.api.wsgi
      ;;
esac
