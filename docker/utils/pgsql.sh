#!/bin/bash

setup_pgsql () {
  # generate the pgservice file if any
  if [[ -n $POSTGRES_DB ]]; then
    # simple setup, a single db is declared using a set of PGxxx env vars
    : > ~/.pgpass
    : > ~/.pg_service.conf
    cat >> ~/.pgpass <<EOF
${PGHOST:-${POSTGRES_DB}-db}:${PGPORT:-5432}:template1:${PGUSER:-postgres}:${PGPASSWORD:-testpassword}
${PGHOST:-${POSTGRES_DB}-db}:${PGPORT:-5432}:${POSTGRES_DB}:${PGUSER:-postgres}:${PGPASSWORD:-testpassword}

EOF

    cat >> ~/.pg_service.conf <<EOF
[${POSTGRES_DB}]
dbname=${POSTGRES_DB}
host=${PGHOST:-${POSTGRES_DB}-db}
port=${PGPORT:-5432}
user=${PGUSER:-postgres}

EOF

  NAME=${POSTGRES_DB}
  PGHOST=${PGHOST:-${POSTGRES_DB}-db}
  PGUSER=${PGUSER:-postgres}
  PGPASSWORD=${PGPASSWORD:-testpassword}

  fi
  if [[ -n $PGCFG_0 ]]; then
	# more generic setup allowing to declare several db access
    # Note that the last one will be considered as the "main" one, i.e.
    # used for init/upgrade purpose;
    : > ~/.pgpass
    : > ~/.pg_service.conf

  for i in {0..10}; do
    CFG="PGCFG_$i"
    if [[ -z ${!CFG} ]]; then
      break
    else
      echo "Configure DB access ${!CFG} (i=${i})"
      # There is probably a better way of doing this...
      NAME=${!CFG}
      PGHOST=PGHOST_$i
      PGHOST=${!PGHOST}
      PGPORT=PGPORT_$i
      PGPORT=${!PGPORT:-5432}
      PGUSER=PGUSER_$i
      PGUSER=${!PGUSER}
      POSTGRES_DB=POSTGRES_DB_$i
      POSTGRES_DB=${!POSTGRES_DB}
      PGPASSWORD=PGPASSWORD_$i
      PGPASSWORD=${!PGPASSWORD}

      cat >> ~/.pgpass <<EOF
${PGHOST}:${PGPORT}:template1:${PGUSER}:${PGPASSWORD}
${PGHOST}:${PGPORT}:${POSTGRES_DB}:${PGUSER}:${PGPASSWORD}

EOF

      cat >> ~/.pg_service.conf <<EOF
[${NAME}]
dbname=${POSTGRES_DB}
host=${PGHOST}
port=${PGPORT}
user=${PGUSER}

EOF

    fi
  done
  fi

  if [[ -f ~/.pgpass ]] ; then
    chmod 0600 ~/.pgpass
    echo "DONE setup Postgresql client config file"
    echo "cat ~/.pg_service.conf"
    cat ~/.pg_service.conf
    echo "====================="
    echo "cat ~/.pgpass"
    cat ~/.pgpass | sed -E 's/:[^:]+$/:****/'
    echo "====================="
    echo "Main DB is ${NAME} (${POSTGRES_DB})"
  fi
}

wait_pgsql () {
  local db_to_check
    if [ $# -ge 1 ]; then
        db_to_check="$1"
    else
        db_to_check=$NAME
    fi

    echo Waiting for postgresql service ${db_to_check} to be available.
    until check_pgsql_db_created ${db_to_check}
  do
    echo -n "."
    sleep 1;
  done
}

check_pgsql_db_created () {
  psql service=$1 -c "select 1" >/dev/null 2>&1
}

swh_setup_db() {
  wait_pgsql

  echo Database setup

  echo " step 1: Creating extensions..."
  swh db init-admin --dbname postgresql:///?service=${NAME} $1

  echo " step 2: Initializing the database..."
  swh db init --flavor ${DB_FLAVOR:-default} $1

  echo " step 3: upgrade"
  swh db upgrade --non-interactive $1

}

swh_setup_dbreplica() {
  echo "This is a replica DB, check for subscription configuration"
  has_publication=$(\
	psql service=${REPLICA_SRC} \
         --quiet --no-psqlrc --no-align --tuples-only -v ON_ERROR_STOP=1 \
         -c "select count(*) from pg_publication where pubname='softwareheritage';" \
  )

  if [ $has_publication -ge 1 ]; then
      echo "Publication found on source database"
  else
      echo "Adding publication to source database"
      replication_contents=$(python -c '
from importlib_metadata import files

for file in files("swh.storage"):
    if str(file).endswith("sql/logical_replication/replication_source.sql"):
        print(file.read_text())
')
      psql service=${REPLICA_SRC} \
           -v ON_ERROR_STOP=1 \
           -c "$replication_contents"
  fi

  has_subscription=$(\
    psql service=${NAME} \
         --quiet --no-psqlrc --no-align --tuples-only -v ON_ERROR_STOP=1 \
         -c "select count(*) from pg_subscription where subname='softwareheritage_replica';" \
  )

  if [ $has_subscription -ge 1 ]; then
      echo "Subscription found on replica database"
  else
      echo "Adding subscription to replica database"
      psql service=${NAME} -c "CREATE SUBSCRIPTION softwareheritage_replica CONNECTION '${REPLICA_SRC_DSN}' PUBLICATION softwareheritage;"
  fi
}
