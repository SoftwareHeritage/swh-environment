#!/bin/bash

setup_pgsql () {
    : > ~/.pgpass

    echo "${PGHOST}:5432:template1:${PGUSER}:${POSTGRES_PASSWORD}" >> ~/.pgpass
    echo "${PGHOST}:5432:${PGUSER}:${PGUSER}:${POSTGRES_PASSWORD}" >> ~/.pgpass
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
    local db_to_check
    if [ $# -ge 1 ]; then
        db_to_check="$1"
    else
        db_to_check=$POSTGRES_DB
    fi

    echo Waiting for postgresql to start and for database $db_to_check to be available.
    wait-for-it ${PGHOST}:5432 -s --timeout=0
    until psql "dbname=${db_to_check} port=5432 host=${PGHOST} user=${PGUSER}" -c "select 'postgresql is up!' as connected"; do sleep 1; done
}

check_pgsql_db_created () {
    psql "dbname=${POSTGRES_DB} port=5432 host=${PGHOST} user=${PGUSER}" -c "select 'postgresql is up!' as connected" >/dev/null 2>/dev/null
}
