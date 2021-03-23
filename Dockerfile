# If true, install from locally cloned modules
# If false, use pip
ARG LOCAL_MODULES=true
ARG SWH_MODULES="swh-core swh-model swh-objstorage"

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
RUN pip install flask gunicorn httpie

###
# swh-packages
FROM swh-base as swh-packages

# Install requirements.txt only if there is any changes
COPY swh-model/requirements.txt /app/requirements-model.txt
COPY swh-core/requirements.txt /app/requirements-core.txt
COPY swh-journal/requirements.txt /app/requirements-journal.txt
COPY swh-objstorage/requirements.txt /app/requirements-objstorage.txt
COPY swh-storage/requirements.txt /app/requirements-storage.txt
RUN . /srv/softwareheritage/venv/bin/activate && cat /app/requirements-*.txt > /tmp/requirements.txt && pip install -r /tmp/requirements.txt \ 
    && pip install decorator aiohttp_utils blinker
    # && rm /srv/requirements*

# Copy source code
COPY swh-model/swh /app/swh
COPY swh-core/swh /app/swh
COPY swh-model/swh /app/swh
COPY swh-objstorage/swh /app/swh
COPY swh-storage/swh /app/swh
