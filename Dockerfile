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

RUN useradd -md /srv/softwareheritage -s /bin/bash swh
USER swh

RUN python3 -m venv /srv/softwareheritage/venv
ENV PATH="/srv/softwareheritage/venv/bin:${PATH}"
RUN pip install --upgrade pip setuptools wheel
RUN pip install gunicorn

RUN pip install \
        swh-deposit \
        swh-indexer \
        swh-journal \
        swh-lister \
        swh-loader-debian \
        swh-loader-dir \
        swh-loader-git \
        swh-loader-mercurial \
        swh-loader-npm \
        swh-loader-pypi \
        swh-loader-svn \
        swh-loader-tar \
        swh-storage \
        swh-objstorage \
        swh-scheduler \
        swh-vault \
        swh-web

COPY utils/*.sh /srv/softwareheritage/utils/
RUN mkdir -p /srv/softwareheritage/objects
