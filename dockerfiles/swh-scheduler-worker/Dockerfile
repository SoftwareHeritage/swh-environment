FROM python:3

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client

RUN pip install swh-scheduler
RUN mkdir /etc/softwareheritage/
COPY scheduler.yml /etc/softwareheritage/
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 5008
