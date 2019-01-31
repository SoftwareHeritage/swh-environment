FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev

RUN pip install -U pip setuptools wheel
RUN pip install swh-objstorage

COPY entrypoint.sh /
COPY objstorage.yml /

RUN mkdir -p /srv/softwareheritage/objects

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 5003
