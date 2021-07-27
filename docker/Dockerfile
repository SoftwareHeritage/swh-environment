FROM python:3.7

RUN . /etc/os-release && echo "deb http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
  echo "deb [signed-by=/usr/share/keyrings/nodejs-archive-keyring.gpg] https://deb.nodesource.com/node_12.x ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/nodejs.list && \
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource.gpg.key | gpg --dearmor > /usr/share/keyrings/nodejs-archive-keyring.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/yarnpkg-archive-keyring.gpg] https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarnpkg.list && \
  curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor > /usr/share/keyrings/yarnpkg-archive-keyring.gpg

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && apt-get upgrade -y && \
  apt-get install -y \
    libapr1-dev \
    libaprutil1-dev \
    libpq-dev \
    libsvn-dev \
    libsystemd-dev \
    gcc \
    memcached \
    openjdk-11-jre \
    pkg-config \
    pv \
    postgresql-client-12 \
    wait-for-it \
    ngrep \
    rsync \
    nodejs \
    yarn \
    zstd && \
  apt-get install -y --no-install-recommends \
    opam \
    r-base-core \
    r-cran-jsonlite && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*


RUN useradd -md /srv/softwareheritage -s /bin/bash swh
USER swh

RUN python3 -m venv /srv/softwareheritage/venv
ENV PATH="/srv/softwareheritage/venv/bin:${PATH}"
RUN pip install --upgrade pip setuptools wheel
RUN pip install gunicorn httpie

RUN pip install \
        swh-core[db,http] \
        swh-counters \
        swh-deposit[server] \
        swh-indexer \
        swh-journal \
        swh-lister \
        swh-loader-core \
        swh-loader-git \
        swh-loader-mercurial \
        swh-loader-svn \
        swh-storage \
        swh-objstorage \
        swh-scheduler \
        swh-vault \
        swh-web

COPY utils/*.sh /srv/softwareheritage/utils/
RUN mkdir -p /srv/softwareheritage/objects
RUN rm -rd /srv/softwareheritage/.cache
