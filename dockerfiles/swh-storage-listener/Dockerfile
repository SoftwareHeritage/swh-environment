FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y libsystemd-dev && \
  apt-get install -y postgresql-client && \
  apt-get install -y wait-for-it

RUN pip install swh-storage kafka_python
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
