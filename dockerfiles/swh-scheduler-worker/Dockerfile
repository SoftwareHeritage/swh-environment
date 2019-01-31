FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client libpq-dev

RUN pip install --upgrade pip setuptools wheel
RUN pip install swh-scheduler --no-binary psycopg2

COPY scheduler.yml /
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
