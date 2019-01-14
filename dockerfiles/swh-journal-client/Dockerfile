FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y libsystemd-dev

RUN pip install swh-journal
COPY logger.yml /etc/softwareheritage/journal/
COPY client.py /
COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
