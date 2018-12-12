# swh-docker-dev

[Work in progress]

This repo contains Dockerfiles to allow developers to run a small
Software Heritage instance on their development computer.

The end goal is to smooth the contributors/developers workflow. Focus
on coding, not configuring!

## How to use

```
make run
```

This will build docker images and run them using docker-compose.

Press Ctrl-C when you want to stop it.

## Details

This runs the following services on their respectively standard ports:

- swh-objstorage

- a `softwareheritage` instance db

- swh-storage (plugged to communicate with the objstorage and the db)

That means, you can start doing the ingestion using those services
using the same setup described in the getting-started [1].

[1] https://docs.softwareheritage.org/devel/getting-started.html#step-4-ingest-repositories
