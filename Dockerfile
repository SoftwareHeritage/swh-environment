FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && apt-get upgrade -y && \
  apt-get install -y \
    libapr1-dev \
    libaprutil1-dev \
    libpq-dev \
    libsvn-dev \
    libsystemd-dev \
    postgresql-client \
    wait-for-it \
    ngrep && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip setuptools wheel
RUN pip install swh-deposit swh-indexer swh-journal swh-lister swh-loader-debian \
                swh-loader-dir swh-loader-git swh-loader-mercurial swh-loader-pypi \
                swh-loader-svn swh-loader-tar swh-storage swh-objstorage \
                swh-scheduler swh-vault swh-web

RUN pip install gunicorn

COPY services/swh-deposit/entrypoint.sh /swh-deposit/entrypoint.sh
COPY services/swh-indexer-journal-client/entrypoint.sh /swh-indexer-journal-client/entrypoint.sh
COPY services/swh-indexer-storage/entrypoint.sh /swh-indexer-storage/entrypoint.sh
COPY services/swh-indexer-worker/entrypoint.sh /swh-indexer-worker/entrypoint.sh
COPY services/swh-journal-client/entrypoint.sh /swh-journal-client/entrypoint.sh
COPY services/swh-listers-worker/entrypoint.sh /swh-listers-worker/entrypoint.sh
COPY services/swh-loaders-worker/entrypoint.sh /swh-loaders-worker/entrypoint.sh
COPY services/swh-objstorage/entrypoint.sh /swh-objstorage/entrypoint.sh
COPY services/swh-scheduler-api/entrypoint.sh /swh-scheduler-api/entrypoint.sh
COPY services/swh-scheduler-worker/entrypoint.sh /swh-scheduler-worker/entrypoint.sh
COPY services/swh-storage/entrypoint.sh /swh-storage/entrypoint.sh
COPY services/swh-vault/entrypoint.sh /swh-vault/entrypoint.sh
COPY services/swh-web/entrypoint.sh /swh-web/entrypoint.sh

COPY services/swh-journal-client/client.py /swh-journal-client/

COPY utils/pgsql.sh /swh-utils/pgsql.sh

RUN useradd -ms /bin/bash swh

RUN mkdir -p /srv/softwareheritage/objects

