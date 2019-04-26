#!/bin/bash

directory=${DIRECTORIES[$RANDOM % ${#DIRECTORIES[@]}]}
revision=${REVISIONS[$RANDOM % ${#REVISIONS[@]}]}

status_message "Requesting the vault to cook a random directory stored into the archive"
http_request_check POST ${SWH_WEB_API_BASEURL}/vault/directory/$directory/

status_message "Waiting for the directory cooking task to complete"
wait_for_service_output 300 swh-vault-worker "swh.vault.cooking_tasks.SWHCookingTask.*succeeded"
status_message "The directory cooking task has been sucessfully executed"

status_message "Checking that the cooked directory tarball can be downloaded"
http_request_check GET ${SWH_WEB_API_BASEURL}/vault/directory/$directory/raw/
status_message "The cooked directory tarball is available for download"

status_message "Requesting the vault to cook a random revision stored into the archive"
http_request_check POST ${SWH_WEB_API_BASEURL}/vault/revision/$revision/gitfast/

status_message "Waiting for the revision cooking task to complete"
wait_for_service_output 300 swh-vault-worker "swh.vault.cooking_tasks.SWHCookingTask.*succeeded"
status_message "The revision cooking task has been sucessfully executed"

status_message "Checking that the cooked revision tarball can be downloaded"
http_request_check GET ${SWH_WEB_API_BASEURL}/vault/revision/$revision/gitfast/raw/
status_message "The cooked revision tarball is available for download"
