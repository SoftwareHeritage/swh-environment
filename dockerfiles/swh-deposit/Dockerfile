FROM python:3

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && apt-get upgrade -y && \
  apt-get install -y libsystemd-dev postgresql-client && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN pip install swh-deposit gunicorn
RUN pip install psycopg2-binary  # to make pip silent
COPY server.yml /etc/softwareheritage/deposit/
COPY private.yml /etc/softwareheritage/deposit/

COPY entrypoint.sh /
EXPOSE 5006
ENTRYPOINT ["/entrypoint.sh"]
