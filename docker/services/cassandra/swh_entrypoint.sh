#!/bin/bash
# /cassandra.yaml is provided by docker-compose via a bind-mount, but
# we need to copy it because the official entrypoint (docker-entrypoint.sh)
# modifies it.
cp /cassandra.yaml /etc/cassandra/cassandra.yaml
exec docker-entrypoint.sh
