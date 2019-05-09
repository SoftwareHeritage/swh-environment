#!/bin/bash

# Main script to run high level tests on the Software Heritage stack

# Use a temporary directory as working directory
WORKDIR=/tmp/swh-docker-dev_tests
# Create it if it does not exist
mkdir $WORKDIR 2>/dev/null
# Ensure it is empty before running the tests
rm -rf $WORKDIR/*

# We want the script to exit at the first encountered error
set -e

# Get test scripts directory
TEST_SCRIPTS_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

# Set the docker-compose.yml file to use
export COMPOSE_FILE=$TEST_SCRIPTS_DIR/../docker-compose.yml

# Useful global variables
SWH_WEB_API_BASEURL="http://localhost:5004/api/1"
CURRENT_TEST_SCRIPT=""

# Colored output related variables and functions
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

function colored_output {
  local msg="$2"
  if [ "$CURRENT_TEST_SCRIPT" != "" ]; then
    msg="[$CURRENT_TEST_SCRIPT] $msg"
  fi
  echo -e "${1}${msg}${NC}"
}

function status_message {
  colored_output ${GREEN} "$1"
}

function error_message {
  colored_output ${RED} "$1"
}

# Exit handler that will get called when this script terminates
function finish {
  if [ $? -ne 0 ] && [ "$CURRENT_TEST_SCRIPT" != "" ]; then
    local SCRIPT_NAME=$CURRENT_TEST_SCRIPT
    CURRENT_TEST_SCRIPT=""
    error_message "An error occurred when running test script ${SCRIPT_NAME}"
    error_message "Dumping logs for all services in file $TEST_SCRIPTS_DIR/swh-docker-compose.logs"
    docker-compose logs > $TEST_SCRIPTS_DIR/swh-docker-compose.logs
  fi
  docker-compose down
  rm -rf $WORKDIR
}
trap finish EXIT

# Docker-compose events listener that will be executed in background
# Parameters:
#   $1: PID of parent process
function listen_docker_events {
  docker-compose events | while read event
  do
    service=$(echo $event | cut -d " " -f7 | sed 's/^name=swh-docker-dev_\(.*\)_1)/\1/')
    event_type=$(echo $event | cut -d ' ' -f4)
    # "docker-compose down" has been called, exiting this child process
    if [ "$event_type" = "kill" ] ; then
      exit
    # a swh service crashed, sending signal to parent process to exit with error
    elif [ "$event_type" = "die" ] ; then
      if [[ "$service" =~ ^swh.* ]]; then
        error_message "Service $service died unexpectedly, exiting"
        kill -s SIGUSR1 $1; exit
      fi
    fi
  done
}
trap "exit 1" SIGUSR1

declare -A SERVICE_LOGS_NB_LINES_READ

# Function to wait for a specific string to be outputted in a specific
# docker-compose service logs.
# When called multiple times on the same service, only the newly outputted
# logs since the last call will be processed.
# Parameters:
#   $1: a timeout value in seconds to stop waiting and exit with error
#   $2: docker-compose service name
#   $3: the string to look for in the produced logs
function wait_for_service_output {
  local nb_lines_to_skip=0
  if [[ -v "SERVICE_LOGS_NB_LINES_READ[$2]" ]]; then
    let nb_lines_to_skip=${SERVICE_LOGS_NB_LINES_READ[$2]}+1
  fi
  SECONDS=0
  local service_logs=$(docker-compose logs $2 | tail -n +$nb_lines_to_skip)
  until echo -ne "$service_logs" | grep -m 1 "$3" >/dev/null ; do
    sleep 1;
    if (( $SECONDS > $1 )); then
      error_message "Could not find pattern \"$3\" in $2 service logs after $1 seconds"
      exit 1
    fi
    let nb_lines_to_skip+=$(echo -ne "$service_logs" | wc -l)
    service_logs=$(docker-compose logs $2 | tail -n +$nb_lines_to_skip)
  done
  let nb_lines_to_skip+=$(echo -ne "$service_logs" | wc -l)
  SERVICE_LOGS_NB_LINES_READ[$2]=$nb_lines_to_skip
}

# Function to make an HTTP request and gets its response.
# It should be used the following way:
#   response=$(http_request <method> <url>)
# Parameters:
#   $1: http method name (GET, POST, ...)
#   $2: request url
function http_request {
  local response=$(curl -sS -X $1 $2)
  echo $response
}

# Function to check that an HTTP request ends up with no errors.
# If the HTTP response code is different from 200, an error will
# be raised and the main script will terminate
# Parameters:
#   $1: http method name (GET, POST, ...)
#   $2: request url
function http_request_check {
  curl -sSf -X $1 $2 > /dev/null
}

# Function to run the content of a script dedicated to test a specific
# part of the Software Heritage stack.
function run_test_script {
  local SCRIPT_NAME=$(basename $1)
  status_message "Executing test script $SCRIPT_NAME"
  CURRENT_TEST_SCRIPT=$SCRIPT_NAME
  source $1
}

# Move to work directory
cd $WORKDIR

# Start the docker-compose event handler as a background process
status_message "Starting docker-compose events listener"
listen_docker_events $$ &

# Start the docker-compose environment including the full Software Heritage stack
status_message "Starting swh docker-compose environment"
docker-compose up -d

# Ensure all swh services are up before running tests
status_message "Waiting for swh services to be up"
docker-compose exec swh-storage wait-for-it localhost:5002 -s --timeout=0
docker-compose exec swh-objstorage wait-for-it localhost:5003 -s --timeout=0
docker-compose exec swh-web wait-for-it localhost:5004 -s --timeout=0
docker-compose exec swh-vault-api wait-for-it localhost:5005 -s --timeout=0
docker-compose exec swh-deposit wait-for-it localhost:5006 -s --timeout=0
docker-compose exec swh-idx-storage wait-for-it localhost:5007 -s --timeout=0
docker-compose exec swh-scheduler-api wait-for-it localhost:5008 -s --timeout=0

# Execute test scripts
for test_script in $TEST_SCRIPTS_DIR/test_*; do
  run_test_script ${test_script}
  CURRENT_TEST_SCRIPT=""
done
