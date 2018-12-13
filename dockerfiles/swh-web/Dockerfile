FROM python:3

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && apt-get upgrade -y && \
  apt-get install -y libsystemd-dev gunicorn3 && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN pip install swh-web

RUN python3 -m swh.web.manage migrate

RUN pip install psycopg2-binary  # to make pip silent

COPY web.yml /etc/softwareheritage/web/

RUN cat /etc/softwareheritage/web/web.yml

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 5004
