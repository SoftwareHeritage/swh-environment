###
# Base image mother of all
FROM python:3.7 as swh-base

RUN . /etc/os-release && echo "deb http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && apt-get upgrade -y && \
  apt-get install -y \
    libapr1-dev \
    libaprutil1-dev \
    libpq-dev \
    libsvn-dev \
    libsystemd-dev \
    memcached \
    postgresql-client-12 \
    wait-for-it \
    ngrep \
    rsync && \
  apt-get install -y --no-install-recommends \
    r-base-core \
    r-cran-jsonlite && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN useradd -md /srv/softwareheritage -s /bin/bash swh

RUN mkdir /app
WORKDIR /app

USER swh

RUN python3 -m venv /srv/softwareheritage/venv
ENV PATH="/srv/softwareheritage/venv/bin:${PATH}"

RUN pip install --upgrade pip setuptools wheel
RUN pip install flask gunicorn httpie decorator aiohttp_utils blinker

###
# swh-packages
FROM swh-base as swh-packages

# Install command line
# RUN pip install swh-core

# Install requirements.txt only if there is any changes

# COPY swh-model/requirements.txt /app/requirements-model.txt
# COPY swh-core/requirements.txt /app/requirements-core.txt
# COPY swh-journal/requirements.txt /app/requirements-journal.txt

# RUN cat /app/requirements-*.txt > /tmp/requirements.txt && pip install -r /tmp/requirements.txt
    # && rm /srv/requirements*

# Copy source code
COPY swh-model /app/swh-model
COPY swh-core /app/swh-core
COPY swh-journal /app/swh-journal
RUN pip install swh-model && pip install swh-core && pip install swh-journal
