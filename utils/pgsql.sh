#!/bin/bash

setup_pgsql () {
    echo "${PGHOST}:5432:postgres:${PGUSER}:${POSTGRES_PASSWORD}" > ~/.pgpass
    echo "${PGHOST}:5432:${POSTGRES_DB}:${PGUSER}:${POSTGRES_PASSWORD}" >> ~/.pgpass
    cat > ~/.pg_service.conf <<EOF
[${POSTGRES_DB}]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF
    chmod 0600 ~/.pgpass
}

wait_pgsql () {
    echo Waiting for postgresql to start
    wait-for-it ${PGHOST}:5432 -s --timeout=0
    until psql postgresql:///?service=${POSTGRES_DB} -c "select 1" > /dev/null 2> /dev/null; do sleep 1; done
}