FROM python:3

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev

RUN pip install swh-objstorage
COPY objstorage.yml /
COPY entrypoint.sh /

RUN mkdir -p /srv/softwareheritage/objects

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 5003
