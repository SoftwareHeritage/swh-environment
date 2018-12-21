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

```
docker-compose up
```

This will build docker images and run them.

Press Ctrl-C when you want to stop it.

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

This runs the following services on their respectively standard ports,
all of the following services are configured to communicate with each
other:

- swh-storage-db: a `softwareheritage` instance db that stores the
  Merkle DAG,

- swh-objstorage: Content-addressable object storage,

- swh-storage: Abstraction layer over the archive, allowing to access
  all stored source code artifacts as well as their metadata,

- swh-web: the swh's web interface over the storage,

- swh-scheduler: the API service as well as 2 utilities,
  the runner and the listener,

- swh-lister: celery workers dedicated to running lister tasks,

- swh-loaders: celery workers dedicated to importing/updating source code
  content (VCS repos, source packages, etc.),

- swh-journal: Persistent logger of changes to the archive, with
  publish-subscribe support.

That means, you can start doing the ingestion using those services
using the same setup described in the getting-started starting
directly at [1].  Yes, even browsing the web app!

[1] https://docs.softwareheritage.org/devel/getting-started.html#step-4-ingest-repositories


## Importing contents



### Inserting a new lister task

To list the content of a source code provider like github or the Debian
distribution, you may add a new task for this.

This task should then spawn a series of loader tasks.

For example, to add a recurring task that will scrape and maintain updated
the Debian stretch distribution, one can do (from this git repository):

```
$ docker-compose run swh-scheduler-api \
    swh-scheduler -c remote -u http://swh-scheduler-api:5008/ \
	    task add swh-lister-gitlab-full -p oneshot instance=https://0xacab.org

Created 1 tasks

Task 12
  Next run: just now (2018-12-19 14:58:49+00:00)
  Interval: 90 days, 0:00:00
  Type: swh-lister-gitlab-full
  Policy: oneshot
  Args:
  Keyword args:
    instance: https://0xacab.org
```

This will insert a new task in the scheduler. To list existing tasks for a
given task type:

```
$ docker-compose run swh-scheduler-api \
  swh-scheduler -c remote -u http://swh-scheduler-api:5008/ \
    task list-pending swh-lister-gitlab-full

Found 1 swh-lister-gitlab-full tasks

Task 12
  Next run: 2 minutes ago (2018-12-19 14:58:49+00:00)
  Interval: 90 days, 0:00:00
  Type: swh-lister-gitlab-full
  Policy: oneshot
  Args:
  Keyword args:
    instance: https://0xacab.org
```

To list all existing task types:

```
$ docker-compose run swh-scheduler-api \
  swh-scheduler -c remote -u http://swh-scheduler-api:5008/ \
    task --list-types

Known task types:
swh-loader-mount-dump-and-load-svn-repository:
  Loading svn repositories from svn dump
origin-update-svn:
  Create dump of a remote svn repository, mount it and load it
swh-deposit-archive-loading:
  Loading deposit archive into swh through swh-loader-tar
swh-deposit-archive-checks:
  Pre-checking deposit step before loading into swh archive
swh-vault-cooking:
  Cook a Vault bundle
origin-update-hg:
  Loading mercurial repository swh-loader-mercurial
origin-load-archive-hg:
  Loading archive mercurial repository swh-loader-mercurial
origin-update-git:
  Update an origin of type git
swh-lister-github-incremental:
  Incrementally list GitHub
swh-lister-github-full:
  Full update of GitHub repos list
swh-lister-debian:
  List a Debian distribution
swh-lister-gitlab-incremental:
  Incrementally list a Gitlab instance
swh-lister-gitlab-full:
  Full update of a Gitlab instance's repos list
swh-lister-pypi:
  Full pypi lister
origin-update-pypi:
  Load Pypi origin
indexer_mimetype:
  Mimetype indexer task
indexer_range_mimetype:
  Mimetype Range indexer task
indexer_fossology_license:
  Fossology license indexer task
indexer_range_fossology_license:
  Fossology license range indexer task
indexer_origin_head:
  Origin Head indexer task
indexer_revision_metadata:
  Revision Metadata indexer task
indexer_origin_metadata:
  Origin Metadata indexer task

```


### Monitoring activity

You can monitor the workers activity by connecting to the RabbitMQ console
on `http://localhost:5018`

If you cannot see any task being in fact executed, check the logs of the
`swh-scheduler-runner` service (here is an ecample of failure due to the
debian lister task not being properly registered on the swh-scheduler-runner
service):

```
$ docker-compose logs --tail=10 swh-scheduler-runner
Attaching to swh-docker-dev_swh-scheduler-runner_1
swh-scheduler-runner_1    |     "__main__", mod_spec)
swh-scheduler-runner_1    |   File "/usr/local/lib/python3.7/runpy.py", line 85, in _run_code
swh-scheduler-runner_1    |     exec(code, run_globals)
swh-scheduler-runner_1    |   File "/usr/local/lib/python3.7/site-packages/swh/scheduler/celery_backend/runner.py", line 107, in <module>
swh-scheduler-runner_1    |     run_ready_tasks(main_backend, main_app)
swh-scheduler-runner_1    |   File "/usr/local/lib/python3.7/site-packages/swh/scheduler/celery_backend/runner.py", line 81, in run_ready_tasks
swh-scheduler-runner_1    |     task_types[task['type']]['backend_name']
swh-scheduler-runner_1    |   File "/usr/local/lib/python3.7/site-packages/celery/app/registry.py", line 21, in __missing__
swh-scheduler-runner_1    |     raise self.NotRegistered(key)
swh-scheduler-runner_1    | celery.exceptions.NotRegistered: 'swh.lister.debian.tasks.DebianListerTask'
```
