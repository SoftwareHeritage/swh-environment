Docker environment
==================

``swh-environment/docker/`` contains Dockerfiles to run a small Software Heritage
instance on development machines. The end goal is to smooth the
contributors/developers workflow. Focus on coding, not configuring!

.. warning::
   Running a Software Heritage instance on your machine can
   consume quite a bit of resources: if you play a bit too hard (e.g., if
   you try to list all GitHub repositories with the corresponding lister),
   you may fill your hard drive, and consume a lot of CPU, memory and
   network bandwidth.

Dependencies
------------

This uses docker with docker-compose, so ensure you have a working
docker environment and docker-compose is installed.

We recommend using the latest version of docker, so please read
https://docs.docker.com/install/linux/docker-ce/debian/ for more details
on how to install docker on your machine.

On a debian system, docker-compose can be installed from Debian
repositories::

   ~$ sudo apt install docker-compose

Quick start
-----------

First, change to the docker dir if you aren’t there yet::

   ~$ cd swh-environment/docker

Then, start containers::

   ~/swh-environment/docker$ docker-compose up -d
   [...]
   Creating docker_amqp_1               ... done
   Creating docker_zookeeper_1          ... done
   Creating docker_kafka_1              ... done
   Creating docker_flower_1             ... done
   Creating docker_swh-scheduler-db_1   ... done
   [...]

This will build docker images and run them. Check everything is running
fine with::

   ~/swh-environment/docker$ docker-compose ps
                            Name                                       Command               State                                      Ports
   -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
   docker_amqp_1                                    docker-entrypoint.sh rabbi ...   Up      15671/tcp, 0.0.0.0:5018->15672/tcp, 25672/tcp, 4369/tcp, 5671/tcp, 5672/tcp
   docker_flower_1                                  flower --broker=amqp://gue ...   Up      0.0.0.0:5555->5555/tcp
   docker_kafka_1                                   start-kafka.sh                   Up      0.0.0.0:5092->5092/tcp
   docker_swh-deposit-db_1                          docker-entrypoint.sh postgres    Up      5432/tcp
   docker_swh-deposit_1                             /entrypoint.sh                   Up      0.0.0.0:5006->5006/tcp
   [...]

The startup of some containers may fail the first time for
dependency-related problems. If some containers failed to start, just
run the ``docker-compose up -d`` command again.

If a container really refuses to start properly, you can check why using
the ``docker-compose logs`` command. For example::

   ~/swh-environment/docker$ docker-compose logs swh-lister
   Attaching to docker_swh-lister_1
   [...]
   swh-lister_1                      | Processing /src/swh-scheduler
   swh-lister_1                      | Could not install packages due to an EnvironmentError: [('/src/swh-scheduler/.hypothesis/unicodedata/8.0.0/charmap.json.gz', '/tmp/pip-req-build-pm7nsax3/.hypothesis/unicodedata/8.0.0/charmap.json.gz', "[Errno 13] Permission denied: '/src/swh-scheduler/.hypothesis/unicodedata/8.0.0/charmap.json.gz'")]
   swh-lister_1                      |

Once all containers are running, you can use the web interface by
opening http://localhost:5080/ in your web browser.

At this point, the archive is empty and needs to be filled with some
content. To do so, you can create tasks that will scrape a forge. For
example, to inject the code from the https://0xacab.org gitlab forge::

   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
       swh scheduler task add list-gitlab-full \
         -p oneshot url=https://0xacab.org/api/v4

   Created 1 tasks

   Task 1
     Next run: just now (2018-12-19 14:58:49+00:00)
     Interval: 90 days, 0:00:00
     Type: list-gitlab-full
     Policy: oneshot
     Args:
     Keyword args:
       url=https://0xacab.org/api/v4

This task will scrape the forge’s project list and register origins to the scheduler.
This takes at most a couple of minutes.

Then, you must tell the scheduler to create loading tasks for these origins.
For example, to create tasks for 100 of these origins::

   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
       swh scheduler origin schedule-next git 100

This will take a bit of time to complete.

To increase the speed at which git repositories are imported, you can
spawn more ``swh-loader-git`` workers::

   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
       celery status
   listers@50ac2185c6c9: OK
   loader@b164f9055637: OK
   indexer@33bc6067a5b8: OK
   vault@c9fef1bbfdc1: OK

   4 nodes online.
   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
       celery control pool_grow 3 -d loader@b164f9055637
   -> loader@b164f9055637: OK
           pool will grow
   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
       celery inspect -d loader@b164f9055637 stats | grep prefetch_count
          "prefetch_count": 4

Now there are 4 workers ingesting git repositories. You can also
increase the number of ``swh-loader-git`` containers::

   ~/swh-environment/docker$ docker-compose up -d --scale swh-loader=4
   [...]
   Creating docker_swh-loader_2        ... done
   Creating docker_swh-loader_3        ... done
   Creating docker_swh-loader_4        ... done

Updating the docker image
-------------------------

All containers started by ``docker-compose`` are bound to a docker image
named ``swh/stack`` including all the software components of Software
Heritage. When new versions of these components are released, the docker
image will not be automatically updated. In order to update all Software
Heritage components to their latest version, the docker image needs to
be explicitly rebuilt by issuing the following command from within the
``docker`` directory::

   ~/swh-environment/docker$ docker build --no-cache -t swh/stack .

Details
-------

This runs the following services on their respectively standard ports,
all of the following services are configured to communicate with each
other:

-  swh-storage-db: a ``softwareheritage`` instance db that stores the
   Merkle DAG,

-  swh-objstorage: Content-addressable object storage,

-  swh-storage: Abstraction layer over the archive, allowing to access
   all stored source code artifacts as well as their metadata,

-  swh-web: the Software Heritage web user interface (with a default "admin"
   account with password "admin"),

-  swh-scheduler: the API service as well as 2 utilities, the runner and
   the listener,

-  swh-lister: celery workers dedicated to running lister tasks,

-  swh-loaders: celery workers dedicated to importing/updating source
   code content (VCS repos, source packages, etc.),

-  swh-journal: Persistent logger of changes to the archive, with
   publish-subscribe support.

That means you can start doing the ingestion using those services using
the same setup described in the getting-started starting directly at
https://docs.softwareheritage.org/devel/getting-started.html#step-4-ingest-repositories

Exposed Ports
^^^^^^^^^^^^^

Several services have their listening ports exposed on the host:

-  amqp: 5072
-  kafka: 5092
-  nginx: 5080

And for SWH services:

-  scheduler API: 5008
-  storage API: 5002
-  object storage API: 5003
-  indexer API: 5007
-  web app: 5004
-  deposit app: 5006

Beware that these ports are not the same as the ports used from within
the docker network. This means that the same command executed from the
host or from a docker container will not use the same urls to access
services. For example, to use the ``celery`` utility from the host, you
may type::

   ~/swh-environment/docker$ CELERY_BROKER_URL=amqp://:5072// celery status
   loader@61704103668c: OK
   [...]

To run the same command from within a container::

   ~/swh-environment/docker$ docker-compose exec swh-scheduler celery status
   loader@61704103668c: OK
   [...]


To consume ``kafka`` topics from the host, for example to run the `swh
dataset graph export` command, a configuration file could be::

  ~/swh-environment/docker$ cat dataset_config.yml
  journal:
    brokers:
      - 127.0.0.1:5092

  ~/swh-environment/docker$ swh dataset -C dataset_config.yml graph export output
  Exporting release:
  - Partition offsets: 100%|███████████████████████████████| 16/16 [00:00<00:00, 1863.62it/s]
  - Export (release): 100%|████████████████| 3650/3650 [00:08<00:00, 437.89it/s, workers=1/1]
  [...]


.. _docker-manage-tasks:

Managing tasks
--------------

One of the main components of the Software Heritage platform is the task
system. These are used to manage everything related to background
process, like discovering new git repositories to import, ingesting
them, checking a known repository is up to date, etc.

The task system is based on Celery but uses a custom database-based
scheduler.

So when we refer to the term ‘task’, it may designate either a Celery
task or a SWH one (ie. the entity in the database). When we refer to
simply a “task” in the documentation, it designates the SWH task.

When a SWH task is ready to be executed, a Celery task is created to
handle the actual SWH task’s job. Note that not all Celery tasks are
directly linked to a SWH task (some SWH tasks are implemented using a
Celery task that spawns Celery subtasks).

A (SWH) task can be ``recurring`` or ``oneshot``. ``oneshot`` tasks are
only executed once, whereas ``recurring`` are regularly executed. The
scheduling configuration of these recurring tasks can be set via the
fields ``current_interval`` and ``priority`` (can be ‘high’, ‘normal’ or
‘low’) of the task database entity.

.. _docker-schedule-lister-task:

Inserting a new lister task
^^^^^^^^^^^^^^^^^^^^^^^^^^^

To list the content of a source code provider like github or a Debian
distribution, you may add a new task for this.

This task will (generally) scrape a web page or use a public API to
identify the list of published software artefacts (git repos, debian
source packages, etc.)

Then, for each repository, a new task will be created to ingest this
repository and keep it up to date.

For example, to add a (one shot) task that will list git repos on the
0xacab.org gitlab instance, one can do (from this git repository)::

   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
       swh scheduler task add list-gitlab-full \
         -p oneshot url=https://0xacab.org/api/v4

   Created 1 tasks

   Task 12
     Next run: just now (2018-12-19 14:58:49+00:00)
     Interval: 90 days, 0:00:00
     Type: list-gitlab-full
     Policy: oneshot
     Args:
     Keyword args:
       url=https://0xacab.org/api/v4

This will insert a new task in the scheduler. To list existing tasks for
a given task type::

   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
     swh scheduler task list-pending list-gitlab-full

   Found 1 list-gitlab-full tasks

   Task 12
     Next run: 2 minutes ago (2018-12-19 14:58:49+00:00)
     Interval: 90 days, 0:00:00
     Type: list-gitlab-full
     Policy: oneshot
     Args:
     Keyword args:
       url=https://0xacab.org/api/v4

To list all existing task types::

   ~/swh-environment/docker$ docker-compose exec swh-scheduler \
     swh scheduler task-type list

   Known task types:
   load-svn-from-archive:
     Loading svn repositories from svn dump
   load-svn:
     Create dump of a remote svn repository, mount it and load it
   load-deposit:
     Loading deposit archive into swh through swh-loader-tar
   check-deposit:
     Pre-checking deposit step before loading into swh archive
   cook-vault-bundle:
     Cook a Vault bundle
   load-hg:
     Loading mercurial repository swh-loader-mercurial
   load-hg-from-archive:
     Loading archive mercurial repository swh-loader-mercurial
   load-git:
     Update an origin of type git
   list-github-incremental:
     Incrementally list GitHub
   list-github-full:
     Full update of GitHub repos list
   list-debian-distribution:
     List a Debian distribution
   list-gitlab-incremental:
     Incrementally list a Gitlab instance
   list-gitlab-full:
     Full update of a Gitlab instance's repos list
   list-pypi:
     Full pypi lister
   load-pypi:
     Load Pypi origin
   index-mimetype:
     Mimetype indexer task
   index-mimetype-for-range:
     Mimetype Range indexer task
   index-fossology-license:
     Fossology license indexer task
   index-fossology-license-for-range:
     Fossology license range indexer task
   index-origin-head:
     Origin Head indexer task
   index-revision-metadata:
     Revision Metadata indexer task
   index-origin-metadata:
     Origin Metadata indexer task

Monitoring activity
^^^^^^^^^^^^^^^^^^^

You can monitor the workers activity by connecting to the RabbitMQ
console on ``http://localhost:5080/rabbitmq`` or the grafana dashboard
on ``http://localhost:5080/grafana``.

If you cannot see any task being executed, check the logs of the
``swh-scheduler-runner`` service (here is a failure example due to the
debian lister task not being properly registered on the
swh-scheduler-runner service)::

   ~/swh-environment/docker$ docker-compose logs --tail=10 swh-scheduler-runner
   Attaching to docker_swh-scheduler-runner_1
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

Using docker setup development and integration testing
------------------------------------------------------

If you hack the code of one or more archive components with a virtual
env based setup as described in the
[[https://docs.softwareheritage.org/devel/developer-setup.html|developer
setup guide]], you may want to test your modifications in a working
Software Heritage instance. The simplest way to achieve this is to use
this docker-based environment.

If you haven’t followed the
[[https://docs.softwareheritage.org/devel/developer-setup.html|developer
setup guide]], you must clone the the [swh-environment] repo in your
``swh-environment`` directory::

   ~/swh-environment$ git clone https://forge.softwareheritage.org/source/swh-environment.git .

Note the ``.`` at the end of this command: we want the git repository to
be cloned directly in the ``~/swh-environment`` directory, not in a sub
directory. Also note that if you haven’t done it yet and you want to
hack the source code of one or more Software Heritage packages, you
really should read the
[[https://docs.softwareheritage.org/devel/developer-setup.html|developer
setup guide]].

From there, we will checkout or update all the swh packages::

   ~/swh-environment$ ./bin/update

Install a swh package from sources in a container
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

It is possible to run a docker container with some swh packages
installed from sources instead of using the latest published packages
from pypi. To do this you must write a docker-compose override file
(``docker-compose.override.yml``). An example is given in the
``docker-compose.override.yml.example`` file:

.. code:: yaml

   version: '2'

   services:
     swh-objstorage:
       volumes:
         - "$HOME/swh-environment/swh-objstorage:/src/swh-objstorage"

The file named ``docker-compose.override.yml`` will automatically be
loaded by ``docker-compose``.

This example shows the simplest case of the ``swh-objstorage`` package:
you just have to mount it in the container in ``/src`` and the
entrypoint will ensure every swh-\* package found in ``/src/`` is
installed (using ``pip install -e`` so you can easily hack your code).
If the application you play with has autoreload support, there is no
need to restart the impacted container.)

Using locally installed swh tools with docker
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

In all examples above, we have executed swh commands from within a
running container. Now we also have these swh commands locally available
in our virtual env, we can use them to interact with swh services
running in docker containers.

For this, we just need to configure a few environment variables. First,
ensure your Software Heritage virtualenv is activated (here, using
virtualenvwrapper)::

   ~$ workon swh
   (swh) ~/swh-environment$ export SWH_SCHEDULER_URL=http://127.0.0.1:5008/
   (swh) ~/swh-environment$ export CELERY_BROKER_URL=amqp://127.0.0.1:5072/

Now we can use the ``celery`` command directly to control the celery
system running in the docker environment::

   (swh) ~/swh-environment$ celery status
   vault@c9fef1bbfdc1: OK
   listers@ba66f18e7d02: OK
   indexer@cb14c33cbbfb: OK
   loader@61704103668c: OK

   4 nodes online.
   (swh) ~/swh-environment$ celery control -d loader@61704103668c pool_grow 3

And we can use the ``swh-scheduler`` command all the same::

   (swh) ~/swh-environment$ swh scheduler task-type list
   Known task types:
   index-fossology-license:
     Fossology license indexer task
   index-mimetype:
     Mimetype indexer task
   [...]

Make your life a bit easier
^^^^^^^^^^^^^^^^^^^^^^^^^^^

When you use virtualenvwrapper, you can add postactivation commands::

   (swh) ~/swh-environment$ cat >>$VIRTUAL_ENV/bin/postactivate <<'EOF'
   # unfortunately, the interface cmd for the click autocompletion
   # depends on the shell
   # https://click.palletsprojects.com/en/7.x/bashcomplete/#activation

   shell=$(basename $SHELL)
   case "$shell" in
       "zsh")
           autocomplete_cmd=source_zsh
           ;;
       *)
           autocomplete_cmd=source
           ;;
   esac

   eval "$(_SWH_COMPLETE=$autocomplete_cmd swh)"
   export SWH_SCHEDULER_URL=http://127.0.0.1:5008/
   export CELERY_BROKER_URL=amqp://127.0.0.1:5072/
   export COMPOSE_FILE=~/swh-environment/docker/docker-compose.yml:~/swh-environment/docker/docker-compose.override.yml
   alias doco=docker-compose

   EOF

This postactivate script does:

-  install a shell completion handler for the swh-scheduler command,
-  preset a bunch of environment variables

   -  ``SWH_SCHEDULER_URL`` so that you can just run ``swh scheduler``
      against the scheduler API instance running in docker, without
      having to specify the endpoint URL,

   -  ``CELERY_BROKER`` so you can execute the ``celery`` tool (without
      cli options) against the rabbitmq server running in the docker
      environment,

   -  ``COMPOSE_FILE`` so you can run ``docker-compose`` from
      everywhere,

-  create an alias ``doco`` for ``docker-compose`` because this is way
   too long to type,

So now you can easily:

-  Start the SWH platform::

     (swh) ~/swh-environment$ doco up -d
     [...]

-  Check celery::

     (swh) ~/swh-environment$ celery status
     listers@50ac2185c6c9: OK
     loader@b164f9055637: OK
     indexer@33bc6067a5b8: OK

-  List task-types::

     (swh) ~/swh-environment$ swh scheduler task-type list
     [...]

-  Get more info on a task type::

     (swh) ~/swh-environment$ swh scheduler task-type list -v -t load-hg
     Known task types:
     load-hg: swh.loader.mercurial.tasks.LoadMercurial
       Loading mercurial repository swh-loader-mercurial
       interval: 1 day, 0:00:00 [1 day, 0:00:00, 1 day, 0:00:00]
       backoff_factor: 1.0
       max_queue_length: 1000
       num_retries: None
       retry_delay: None

-  Add a new task::

     (swh) ~/swh-environment$ swh scheduler task add load-hg \
       origin_url=https://hg.logilab.org/master/cubicweb
     Created 1 tasks
     Task 1
        Next run: just now (2019-02-06 12:36:58+00:00)
        Interval: 1 day, 0:00:00
        Type: load-hg
        Policy: recurring
        Args:
        Keyword args:
          origin_url: https://hg.logilab.org/master/cubicweb

-  Respawn a task::

     (swh) ~/swh-environment$ swh scheduler task respawn 1

.. _docker-persistence:

Data persistence for a development setting
------------------------------------------

The default ``docker-compose.yml`` configuration is not geared towards
data persistence, but application testing.

Volumes defined in associated images are anonymous and may get either
unused or removed on the next ``docker-compose up``.

One way to make sure these volumes persist is to use named volumes. The
volumes may be defined as follows in a ``docker-compose.override.yml``.
Note that volume definitions are merged with other compose files based
on destination path.

::

   services:
     swh-storage-db:
       volumes:
         - "swh_storage_data:/var/lib/postgresql/data"
     swh-objstorage:
       volumes:
         - "swh_objstorage_data:/srv/softwareheritage/objects"

   volumes:
     swh_storage_data:
     swh_objstorage_data:

This way, ``docker-compose down`` without the ``-v`` flag will not
remove those volumes and data will persist.


Additional components
---------------------

We provide some extra modularity in what components to run through
additional ``docker-compose.*.yml`` files.

They are disabled by default, because they add layers of complexity
and increase resource usage, while not being necessary to operate
a small Software Heritage instance.

Starting a kafka-powered mirror of the storage
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

This repo comes with an optional ``docker-compose.storage-mirror.yml``
docker compose file that can be used to test the kafka-powered mirror
mechanism for the main storage.

This can be used like::

   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.storage-mirror.yml \
        up -d
   [...]

Compared to the original compose file, this will:

-  overrides the swh-storage service to activate the kafka direct writer
   on swh.journal.objects prefixed topics using the swh.storage.master
   ID,
-  overrides the swh-web service to make it use the mirror instead of
   the master storage,
-  starts a db for the mirror,
-  starts a storage service based on this db,
-  starts a replayer service that runs the process that listen to kafka
   to keeps the mirror in sync.

When using it, you will have a setup in which the master storage is used
by workers and most other services, whereas the storage mirror will be
used to by the web application and should be kept in sync with the
master storage by kafka.

Note that the object storage is not replicated here, only the graph
storage.

Starting the backfiller
"""""""""""""""""""""""

Reading from the storage the objects from within range [start-object,
end-object] to the kafka topics.

::

   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.storage-mirror.yml \
        -f docker-compose.storage-mirror.override.yml \
        run \
        swh-journal-backfiller \
        snapshot \
        --start-object 000000 \
        --end-object 000001 \
        --dry-run

Cassandra
^^^^^^^^^

We are working on an alternative backend for swh-storage, based on Cassandra
instead of PostgreSQL.

This can be used like::

   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.cassandra.yml \
        up -d
   [...]


This launches two Cassandra servers, and reconfigures swh-storage to use them.

Efficient origin search
^^^^^^^^^^^^^^^^^^^^^^^

By default, swh-web uses swh-storage and swh-indexer-storage to provide its
search bar. They are both based on PostgreSQL and rather inefficient
(or Cassandra, which is even slower).

Instead, you can enable swh-search, which is based on ElasticSearch
and much more efficient, like this::

   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.search.yml \
        up -d
   [...]

Efficient counters
^^^^^^^^^^^^^^^^^^

The web interface shows counters of the number of objects in your archive,
by counting objects in the PostgreSQL or Cassandra database.

While this should not be an issue at the scale of your local Docker instance,
counting objects can actually be a bottleneck at Software Heritage's scale.
So swh-storage uses heuristics, that can be either not very efficient
or inaccurate.

So we have an alternative based on Redis' HyperLogLog feature, which you
can test with::

   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.counters.yml \
        up -d
   [...]


Efficient graph traversals
^^^^^^^^^^^^^^^^^^^^^^^^^^

:ref:`swh-graph <swh-graph>` is a work-in-progress alternative to swh-storage
to perform large graph traversals/queries on the merkle DAG.

For example, it can be used by the vault, as it needs to query all objects
in the sub-DAG of a given node.

You can use it with::

   ~/swh-environment/docker$ docker-compose \
       -f docker-compose.yml \
       -f docker-compose.graph.yml up -d

On the first start, it will run some precomputation based on all objects already
in your local SWH instance; so it may take a long time if you loaded many
repositories. (Expect 5 to 10s per repository.)

It **does not update automatically** when you load new repositories.
You need to restart it every time you want to update it.

You can :ref:`mount a docker volume <docker-persistence>` on
:file:`/srv/softwareheritage/graph` to avoid recomputing this graph
on every start.
Then, you need to explicitly request recomputing the graph before restarts
if you want to update it::

   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.graph.yml \
        run swh-graph update
   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.graph.yml \
        stop swh-graph
   ~/swh-environment/docker$ docker-compose \
        -f docker-compose.yml \
        -f docker-compose.graph.yml \
        up -d swh-graph


Keycloak
^^^^^^^^

If you really want to hack on swh-web's authentication features,
you will need to enable Keycloak as well, instead of the default
Django-based authentication::

   ~/swh-environment/docker$ docker-compose -f docker-compose.yml -f docker-compose.keycloak.yml up -d
   [...]

User registration in Keycloak database is available by following the Register link
in the page located at http://localhost:5080/oidc/login/.

Please note that email verification is required to properly register an account.
As we are in a testing environment, we use a MailHog instance as a fake SMTP server.
All emails sent by Keycloak can be easily read from the MailHog Web UI located
at http://localhost:8025/.


Using Sentry
------------

All entrypoints to SWH code (CLI, gunicorn, celery, …) are, or should
be, instrumented using Sentry. By default this is disabled, but if you
run your own Sentry instance, you can use it.

To do so, you must get a DSN from your Sentry instance, and set it as
the value of ``SWH_SENTRY_DSN`` in the file ``env/common_python.env``.
You may also set it per-service in the ``environment`` section of each
services in ``docker-compose.override.yml``.

Caveats
-------

Running a lister task can lead to a lot of loading tasks, which can fill
your hard drive pretty fast. Make sure to monitor your available storage
space regularly when playing with this stack.

Also, a few containers (``swh-storage``, ``swh-xxx-db``) use a volume
for storing the blobs or the database files. With the default
configuration provided in the ``docker-compose.yml`` file, these volumes
are not persistent. So removing the containers will delete the volumes!

Also note that for the ``swh-objstorage``, since the volume can be
pretty big, the remove operation can be quite long (several minutes is
not uncommon), which may mess a bit with the ``docker-compose`` command.

If you have an error message like:

Error response from daemon: removal of container 928de3110381 is already
in progress

it means that you need to wait for this process to finish before being
able to (re)start your docker stack again.
