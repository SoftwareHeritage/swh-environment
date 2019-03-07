FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y libsystemd-dev && \
  apt-get install -y libapr1-dev libaprutil1-dev && \
  apt-get install -y libsvn-dev && \
  apt-get install -y wait-for-it

RUN pip install \
        swh-loader-debian \
        swh-loader-dir \
        swh-loader-git \
        swh-loader-mercurial \
        swh-loader-pypi \
        swh-loader-svn \
        swh-loader-tar


RUN useradd -ms /bin/bash swh
COPY entrypoint.sh /

USER swh
ENTRYPOINT ["/entrypoint.sh"]
