FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && apt-get upgrade -y && \
  apt-get install -y libsystemd-dev && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN pip install swh-web
RUN pip install psycopg2-binary  # to make pip silent
RUN python3 -m swh.web.manage migrate

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 5004
