# swh-docker-dev

[Work in progress]

This repo contains Dockerfiles to allow developers to run a small
Software Heritage instance on their development computer.

The end goal is to smooth the contributors/developers workflow. Focus
on coding, not configuring!

## Dependencies

This uses docker with docker-compose, so ensure you have a working
docker environment and docker-compose is installed.

## How to use

Initialise the database with:

```
docker-compose run swh-storage init
```

then start the services with:

```
docker-compose up
```

This will build docker images and run them.

Press Ctrl-C when you want to stop it.

Note: the db initialization process is a manual step for now because it
is not yet "idempotent", but (hopefully) this will be fixed any time soon.

To run them in a detached (background) mode:

```
docker-compose up -d
```

To run only the objstorage API:

```
docker-compose up swh-objstorage
```

### Install a package from sources

It is possible to run a docker with some swh packages installed from sources
instead of from pypi. To do this you must write a docker-compose override
file. An example is given in docker-compose.override.yml.example:

```
version: '2'

services:
  swh-objstorage:
    volumes:
      - "/home/ddouard/src/swh-environment/swh-objstorage:/src/swh-objstorage"
```

A file named docker-compose.override.yml will automatically be loaded by
docker-compose.

This example shows the simple case of the swh-objstorage package: you just have to
mount it in the container in /src and the entrypoint will ensure every
swh-* package found in /src/ is installed (using `pip install -e` so you can
easily hack your code. If the application you play with have autoreload support,
there is even no need for restarting the impacted container.)

## Details

This runs the following services on their respectively standard ports:

- swh-objstorage

- a `softwareheritage` instance db that stores the Merkle DAG.

- swh-storage (plugged to communicate with the objstorage and the db)

- swh-web (plugged to communicate with the previous services)

That means, you can start doing the ingestion using those services
using the same setup described in the getting-started starting
directly at [1].  Yes, even browsing the web app!

[1] https://docs.softwareheritage.org/devel/getting-started.html#step-4-ingest-repositories
