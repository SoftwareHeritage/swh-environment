# swh-docker-dev

[Work in progress]

This repo contains Dockerfiles to allow developers to run a small
Software Heritage instance on their development computer.

The end goal is to smooth the contributors/developers workflow. Focus
on coding, not configuring!

## Dependencies

This uses docker with docker-compose, so ensure you have a working
docker environment and docker-compose is installed.

## Warning

Running a Software Heritage instance on your machine can be quickly quite
ressource consuming: if you play a bit too hard (eg. if you try the github
lister), you may fill your hard drive pretty quick, and consume a lot of CPU,
memory and network bandwidth.

## Quick start

First, start containers:

```
~/swh-environment/swh-docker-dev$ docker-compose up -d
[...]
Creating swh-docker-dev_amqp_1               ... done
Creating swh-docker-dev_zookeeper_1          ... done
Creating swh-docker-dev_kafka_1              ... done
Creating swh-docker-dev_flower_1             ... done
Creating swh-docker-dev_swh-scheduler-db_1   ... done
[...]
```

This will build docker images and run them.

Check everything is running fine with:

```
~/swh-environment/swh-docker-dev$ docker-compose ps
                         Name                                       Command               State                                      Ports
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
swh-docker-dev_amqp_1                                    docker-entrypoint.sh rabbi ...   Up      15671/tcp, 0.0.0.0:5018->15672/tcp, 25672/tcp, 4369/tcp, 5671/tcp, 5672/tcp
swh-docker-dev_flower_1                                  flower --broker=amqp://gue ...   Up      0.0.0.0:5555->5555/tcp
swh-docker-dev_kafka_1                                   start-kafka.sh                   Up      0.0.0.0:9092->9092/tcp
swh-docker-dev_swh-deposit-db_1                          docker-entrypoint.sh postgres    Up      5432/tcp
swh-docker-dev_swh-deposit_1                             /entrypoint.sh                   Up      0.0.0.0:5006->5006/tcp
[...]
```

Note: if a container failed to start, it's status will be marked as `Exit 1`
instead of `Up`. You can check why using the `docker-compose logs` command. For
example:

```
~/swh-environment/swh-docker-dev$ docker-compose logs swh-lister-debian
Attaching to swh-docker-dev_swh-lister-debian_1
[...]
swh-lister-debian_1                      | Processing /src/swh-scheduler
swh-lister-debian_1                      | Could not install packages due to an EnvironmentError: [('/src/swh-scheduler/.hypothesis/unicodedata/8.0.0/charmap.json.gz', '/tmp/pip-req-build-pm7nsax3/.hypothesis/unicodedata/8.0.0/charmap.json.gz', "[Errno 13] Permission denied: '/src/swh-scheduler/.hypothesis/unicodedata/8.0.0/charmap.json.gz'")]
swh-lister-debian_1                      |
```

Once all the containers are running, you can use the web interface by opening
http://localhost:5080/ in your web browser.

At this point, the archive is empty and needs to be filled with some content.
To do so, you can create tasks that will scrape a forge. For example, to inject
the code from the https://0xacab.org gitlab forge:

```
$ ~/swh-environment/swh-docker-dev$ docker-compose run swh-scheduler-api \
    swh-scheduler -c remote -u http://swh-scheduler-api:5008/ \
	    task add swh-lister-gitlab-full -p oneshot api_baseurl=https://0xacab.org/api/v4

Created 1 tasks

Task 1
  Next run: just now (2018-12-19 14:58:49+00:00)
  Interval: 90 days, 0:00:00
  Type: swh-lister-gitlab-full
  Policy: oneshot
  Args:
  Keyword args:
    api_baseurl=https://0xacab.org/api/v4
```

This task will scrape the forge's project list and create subtasks to inject
each git repository found there.

This will take a bit af time to complete.

To increase the speed at wich git repositories are imported, you can spawn more
`swh-loader-git` workers:

```
~/swh-environment/swh-docker-dev$ export CELERY_BROKER_URL=amqp://:5072//
~/swh-environment/swh-docker-dev$ celery status
mercurial@8f63da914c26: OK
debian@8a1c6ced237b: OK
debian@d4be158f1759: OK
pypi@41187053b90d: OK
dir@52a19b9ba606: OK
pypi@9be0cdcb484c: OK
github@101d702d6e1d: OK
bitbucket@1770d3b81da8: OK
svn@9b2e473d466b: OK
git@ae6ddafca382: OK
tar@e17c0bc4392d: OK
npm@ccfc73f73c4b: OK
gitlab@280a937595f3: OK

~/swh-environment/swh-docker-dev$ celery control pool_grow 3 -d git@ae6ddafca382
-> git@ae6ddafca382: OK
        pool will grow
~/swh-environment/swh-docker-dev$ celery inspect -d git@ae6ddafca382 stats | grep prefetch_count
       "prefetch_count": 4,
```

Note: this later command assumes you have `celery` available on your host
machine.

Now there are 4 workers ingesting git repositories.
You can also increase the number of `swh-loader-git` containers:

```
~/swh-environment/swh-docker-dev$ docker-compose up -d --scale swh-loader-git=4
[...]
Creating swh-docker-dev_swh-loader-git_2        ... done
Creating swh-docker-dev_swh-loader-git_3        ... done
Creating swh-docker-dev_swh-loader-git_4        ... done
```


### Install a package from sources

It is possible to run a docker container with some swh packages installed from
sources instead of using lastest published packages from pypi. To do this you
must write a docker-compose override file (`docker-compose.override.yml`). An
example is given in the `docker-compose.override.yml.example` file:

```
version: '2'

services:
  swh-objstorage:
    volumes:
      - "/home/ddouard/src/swh-environment/swh-objstorage:/src/swh-objstorage"
```

The file named `docker-compose.override.yml` will automatically be loaded by
`docker-compose`.

This example shows the simple case of the `swh-objstorage` package: you just have to
mount it in the container in `/src` and the entrypoint will ensure every
swh-* package found in `/src/` is installed (using `pip install -e` so you can
easily hack your code. If the application you play with have autoreload support,
there is even no need for restarting the impacted container.)

Note: if the docker fails to start when using local sources for one or more swh
package, it's most probably due to permission problems on cache files. For
example, if you have executed tests locally (using pytest or tox), you have
cache files (__pycache__ etc.) that will prevent `pip install` from working
within the docker.

The solution is to clean these files and directories before trying to spawn the
docker.

```
~/swh-environment$ find . -type d -name __pycache__ -exec rm -rf {} \;
~/swh-environment$ find . -type d -name .tox -exec rm -rf {} \;
~/swh-environment$ find . -type d -name .hypothesis -exec rm -rf {} \;
```


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
directly at [1].

[1] https://docs.softwareheritage.org/devel/getting-started.html#step-4-ingest-repositories

### Exposed Ports

Several services have their listening ports exposed on the host:

- amqp: 5072
- kafka: 5092
- nginx: 5080

And for SWH services:

- scheduler API: 5008
- storage API: 5002
- object storage API: 5003
- indexer API: 5007
- web app: 5004
- deposit app: 5006

Beware that these ports are not the same as the ports used from within the
docker network. This means that the same command executed from the host or from
a docker container will not use the same urls to access services. For example,
to use the `celery` utility from the host, you may type:

```
~/swh-environment/swh-docker-dev$ CELERY_BROKER_URL=amqp://:5072// celery status
dir@52a19b9ba606: OK
[...]
```

To run the same command from within a container:

```
~/swh-environment/swh-docker-dev$ celery-compose exec swh-scheduler-api bash
root@01dba49adf37:/# CELERY_BROKER_URL=amqp://amqp:5672// celery status
dir@52a19b9ba606: OK
[...]
```

## Managing tasks

One of the main components of the Software Heritage platform is the task system.
These are used to manage everything related to background process, like
discovering new git repositories to import, ingesting them, checking a known
repository is up to date, etc.

The task system is based on Celery but uses a custom database-based scheduler.

So when we refer to the term 'task', it may designate either a Celery task or a
SWH one (ie. the entity in the database). When we refer to simply a "task" in
the documentation, it designates the SWH task.

When a SWH task is ready to be executed, a Celery task is created to handle the
actual SWH task's job. Note that not all Celery tasks are directly linked to a
SWH task (some SWH tasks are implemented using a Celery task that spawns Celery
subtasks).

A (SWH) task can be `recurring` or `oneshot`. `oneshot` tasks are only executed
once, whereas `recurring` are regularly executed. The scheduling configuration
of these recurring tasks can be set via the fields `current_interval` and
`priority` (can be 'high', 'normal' or 'low') of the task database entity.


### Inserting a new lister task

To list the content of a source code provider like github or a Debian
distribution, you may add a new task for this.

This task will (generally) scrape a web page or use a public API to identify
the list of published software artefacts (git repos, debian source packages,
etc.)

Then, for each repository, a new task will be created to ingest this repository
and keep it up to date.

For example, to add a (one shot) task that will list git repos on the
0xacab.org gitlab instance, one can do (from this git repository):

```
$ docker-compose run swh-scheduler-api \
    swh-scheduler -c remote -u http://swh-scheduler-api:5008/ \
	    task add swh-lister-gitlab-full -p oneshot api_baseurl=https://0xacab.org/api/v4

Created 1 tasks

Task 12
  Next run: just now (2018-12-19 14:58:49+00:00)
  Interval: 90 days, 0:00:00
  Type: swh-lister-gitlab-full
  Policy: oneshot
  Args:
  Keyword args:
    api_baseurl=https://0xacab.org/api/v4
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
    api_baseurl=https://0xacab.org/api/v4
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

You can monitor the workers activity by connecting to the RabbitMQ console on
`http://localhost:5002` or the Celery dashboard (flower) on
`http://localhost:5003`.

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
