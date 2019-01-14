FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y libsystemd-dev

RUN pip install swh-indexer
COPY journal_client.yml /etc/softwareheritage/indexer/
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

