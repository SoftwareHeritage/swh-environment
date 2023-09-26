#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
setup_pip

source /srv/softwareheritage/utils/pgsql.sh
setup_pgsql

case "$1" in
    "shell")
      exec bash -i
      ;;

    "scrubber")
		shift
        # expected arguments: entity type, number of partitions (as nbits)
        OBJTYPE=$1
        shift
        NBITS=$1
        shift
        CFGNAME="${OBJTYPE}_${NBITS}"

        if [ -v POSTGRES_DB ]; then
            wait_pgsql
			echo "###############################"
			echo "# DB config is"
			cat ~/.pg_service.conf
			echo "###############################"
            echo Database setup
            echo Initializing the database ${POSTGRES_DB}...
            echo " step 1: init-admin"
            python3 -m swh db init-admin --dbname postgresql:///?service=${NAME} scrubber
            echo " step 2: init"
            python3 -m swh db init scrubber
            echo " step 3: upgrade"
            python3 -m swh db upgrade --non-interactive scrubber

            # now create the scrubber config, if needed
            python3 -m swh scrubber check init storage \
					--object-type ${OBJTYPE} \
					--nb-partitions $(( 2 ** ${NBITS} )) \
					--name ${CFGNAME} && \
				echo "Created scrubber configuration ${CFGNAME}" || \
					echo "Configuration ${CFGNAME} already exists (ignored)."
        fi

        echo "Starting a SWH storage scrubber ${CFGNAME}"
        exec python3 -m swh --log-level ${LOG_LEVEL:-WARNING} \
                scrubber check storage ${CFGNAME} $@
        ;;

   *)
        exec $@
        ;;
esac
