#!/bin/bash

# turn on bash's job control
set -m

echo "Starting Keycloak"
/opt/jboss/tools/docker-entrypoint.sh -b 0.0.0.0&
echo "Waiting for Keycloak server to be up"
/wait-for-it.sh localhost:8080 -s --timeout=0
echo "Configuring Keycloak to be used in docker environment"
echo "and creating some test users in the SoftwareHeritage realm"
/keycloak_swh_setup.py
fg %1

