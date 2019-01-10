FROM python:3

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client libpq-dev

RUN pip install swh-scheduler --no-binary psycopg2
RUN mkdir -p /etc/softwareheritage/worker/
COPY scheduler.yml /etc/softwareheritage/
# XXX this should NOT be needed.
# Some cleanup work in config files handling seems necessary...
RUN ln -s /etc/softwareheritage/scheduler.yml /etc/softwareheritage/worker/
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
