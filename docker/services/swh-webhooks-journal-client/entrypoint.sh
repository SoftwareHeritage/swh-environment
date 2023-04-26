#!/bin/bash

set -e

source /srv/softwareheritage/utils/pyutils.sh
source /srv/softwareheritage/utils/swhutils.sh

setup_pip

case "$1" in
    "shell")
      exec bash -i
      ;;
    *)
      echo "Setting up webhook for origin visits"
      wait-for-it svix:8071 -s --timeout=0
      swh -l DEBUG webhooks event-type register-defaults
      secret=$(yq -r .save_code_now_webhook_secret /web.yml)
      swh -l DEBUG webhooks endpoint create origin.visit \
        http://swh-web:5004/save/origin/visit/webhook/ --secret $secret

      echo "Starting swh-webhooks-journal client"
      wait-for-it kafka:9092 -s --timeout=0
      wait-for-topic http://kafka:8082 swh.journal.objects.origin_visit_status
      swh -l DEBUG webhooks journal-client
      ;;
esac
