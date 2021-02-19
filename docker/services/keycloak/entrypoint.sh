#!/bin/bash

# turn on bash's job control
set -m

cd
if [ ! -d swh-keycloak-theme ]
then
  git clone https://forge.softwareheritage.org/source/swh-keycloak-theme.git
  cp -r /opt/jboss/swh-keycloak-theme/swh /opt/jboss/keycloak/themes/swh
fi

echo "Starting Keycloak"
/opt/jboss/tools/docker-entrypoint.sh -b 0.0.0.0&
echo "Waiting for Keycloak server to be up"
/wait-for-it.sh localhost:8080 -s --timeout=0
echo "Configuring Keycloak to be used in docker environment"
echo "and creating some test users in the SoftwareHeritage realm"
/keycloak_swh_setup.py
fg %1

