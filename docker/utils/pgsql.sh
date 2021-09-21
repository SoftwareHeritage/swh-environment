#!/bin/bash

setup_pgsql () {
    : > ~/.pgpass
    : > ~/.pg_service.conf

   # Configure the standard PG env variables (out of the container expected env
   # variables)
   [ -z "$PGDATABASE" ] && export PGDATABASE=$POSTGRES_DB
   [ -z "$PGPASSWORD" ] && export PGPASSWORD=$POSTGRES_PASSWORD

    echo "${PGHOST}:5432:${PGUSER}:${PGUSER}:${PGPASSWORD}" >> ~/.pgpass
    echo "${PGHOST}:5432:${PGDATABASE}:${PGUSER}:${PGPASSWORD}" >> ~/.pgpass
    cat >> ~/.pg_service.conf <<EOF
[${PGDATABASE}]
dbname=${PGDATABASE}
host=${PGHOST}
port=5432
user=${PGUSER}
EOF

    if ! [ -z "$POSTGRES_DB_SRC" ]; then
        echo "${PGHOST_SRC}:5432:${POSTGRES_DB_SRC}:${PGUSER_SRC}:${POSTGRES_PASSWORD_SRC}" >> ~/.pgpass
        cat >> ~/.pg_service.conf <<EOF
[${POSTGRES_DB_SRC}]
dbname=${POSTGRES_DB_SRC}
host=${PGHOST_SRC}
port=5432
user=${PGUSER_SRC}
EOF
    fi

    chmod 0600 ~/.pgpass
}

wait_pgsql () {
    local db_to_check
    if [ $# -ge 1 ]; then
        db_to_check="$1"
    else
        db_to_check=$POSTGRES_DB
    fi

    if [ $# -ge 2 ]; then
        host_to_check="$2"
    else
        host_to_check=$PGHOST
    fi

    echo Waiting for postgresql to start on $host_to_check and for database $db_to_check to be available.
    wait-for-it ${host_to_check}:5432 -s --timeout=0
    until psql "dbname=${db_to_check} port=5432 host=${host_to_check} user=${PGUSER}" -c "select 'postgresql is up!' as connected"; do sleep 1; done
}

check_pgsql_db_created () {
    psql "dbname=${POSTGRES_DB} port=5432 host=${PGHOST} user=${PGUSER}" -c "select 'postgresql is up!' as connected" >/dev/null 2>/dev/null
}
