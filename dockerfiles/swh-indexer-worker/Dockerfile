FROM python:3.6

RUN export DEBIAN_FRONTEND=noninteractive && \
  apt-get update && \
  apt-get install -y \
    libsystemd-dev postgresql-client

RUN pip install swh-indexer
RUN useradd -ms /bin/bash swh
COPY entrypoint.sh /

COPY mimetype.yml /home/swh/.config/swh/indexer/
COPY fossology_license.yml /home/swh/.config/swh/indexer/
COPY origin_head.yml /home/swh/.config/swh/indexer/
COPY revision_metadata.yml /home/swh/.config/swh/indexer/
COPY origin_intrinsic_metadata.yml /home/swh/.config/swh/indexer/
RUN chown -R swh: /home/swh/.config/

USER swh
ENTRYPOINT ["/entrypoint.sh"]
