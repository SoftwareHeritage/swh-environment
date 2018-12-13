FROM python:3

export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client

RUN pip install swh-storage
COPY storage.yml /
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 5002
