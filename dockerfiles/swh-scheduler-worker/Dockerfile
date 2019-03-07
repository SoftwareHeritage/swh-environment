FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y libsystemd-dev && \
  apt-get install -y postgresql-client libpq-dev && \
  apt-get install -y wait-for-it

RUN pip install --upgrade pip setuptools wheel
RUN pip install swh-scheduler --no-binary psycopg2

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
