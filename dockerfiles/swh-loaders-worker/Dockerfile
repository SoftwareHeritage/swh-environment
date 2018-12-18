FROM python:3

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev libapr1-dev libaprutil1-dev libsvn-dev

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

COPY loader.yml /home/swh/.config/swh/
RUN chown -R swh: /home/swh/.config/

USER swh
ENTRYPOINT ["/entrypoint.sh"]
