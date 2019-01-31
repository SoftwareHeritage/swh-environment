FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client

RUN pip install swh-storage kafka_python
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
