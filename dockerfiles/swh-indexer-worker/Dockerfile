FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client

RUN pip install --upgrade pip
RUN pip install swh-indexer
RUN useradd -ms /bin/bash swh

USER swh
COPY entrypoint.sh /
COPY indexer.yml /home/swh/

ENTRYPOINT ["/home/swh/entrypoint.sh"]
