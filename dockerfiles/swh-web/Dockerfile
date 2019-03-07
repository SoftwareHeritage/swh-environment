FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && apt-get upgrade -y && \
  apt-get install -y libsystemd-dev && \
  apt-get install -y pandoc && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN pip install -U pip
RUN pip install swh-web
RUN pip install psycopg2-binary  # to make pip silent
RUN pip install gunicorn
RUN python3 -m swh.web.manage migrate

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
WORKDIR /tmp/swh

EXPOSE 5004
