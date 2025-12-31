FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    gosu \
    libstdc++6 \
    libncurses6 libncursesw6 \
    openssl libssl3 \
    libmagic1t64 file \
    postgresql-client \
    ffmpeg imagemagick libimage-exiftool-perl \
    libvips42t64 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pleroma

COPY pleroma-host-release-entrypoint.sh /usr/local/bin/pleroma-host-release-entrypoint.sh
RUN chmod +x /usr/local/bin/pleroma-host-release-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/pleroma-host-release-entrypoint.sh"]
CMD ["/opt/pleroma/bin/pleroma", "start"]
