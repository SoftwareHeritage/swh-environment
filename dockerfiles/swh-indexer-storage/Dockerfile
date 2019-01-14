FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client

RUN pip install swh-indexer
COPY indexer_storage.yml /
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 5002
