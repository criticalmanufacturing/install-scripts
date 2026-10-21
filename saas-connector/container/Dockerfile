# syntax=docker/dockerfile:1
# Build from the repository root: docker build -f saas-connector/container/Dockerfile .
# Upstream builds the router and its dependencies; we only add the CLI and bootstrap.
FROM --platform=$BUILDPLATFORM docker.io/curlimages/curl:8.16.0@sha256:463eaf6072688fe96ac64fa623fe73e1dbe25d8ad6c34404a669ad3ce1f104b6 AS cli
ARG TARGETARCH
WORKDIR /tmp
RUN case "$TARGETARCH" in \
      amd64) checksum=9eb77dab5f2659becaca53364a38df38746b1850788d2652ef2084fcc3b325ab ;; \
      arm64) checksum=447de7721bd1f6f54c918c951dff5e7d3c660660dea7848cf269bb9cf0df6fa1 ;; \
      *) echo 'Supported architectures: amd64 and arm64' >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 3 "https://github.com/skupperproject/skupper/releases/download/2.2.3/skupper-cli-2.2.3-linux-${TARGETARCH}.tgz" -o cli.tgz \
    && echo "$checksum  cli.tgz" | sha256sum -c - \
    && tar -xzf cli.tgz skupper

FROM quay.io/skupper/skupper-router:3.5.3@sha256:43c75e1573ff33c10102034bb41fbe53b55f5d2067d7d3c9904cfa7bfd09fe8d
USER 0
RUN mkdir -p /output /input /run \
    && chgrp 0 /output && chmod g=u /output \
    && touch /run/.containerenv
COPY --from=cli --chmod=0755 /tmp/skupper /usr/local/bin/skupper-cli
COPY --chmod=0755 saas-connector/container/saas-connector-cli.sh /usr/local/bin/skupper
COPY --chmod=0755 saas-connector/container/entrypoint.sh saas-connector/container/healthcheck.sh /usr/local/bin/
ENV HOME=/output/home \
    XDG_DATA_HOME=/output/data \
    XDG_CONFIG_HOME=/output/config \
    XDG_RUNTIME_DIR=/output/run \
    SKUPPER_OUTPUT_PATH=/output \
    SKUPPER_PLATFORM=linux \
    PYTHONDONTWRITEBYTECODE=1
# OpenShift replaces this UID; no fixed UID or fsGroup is needed in the pod.
USER 10001:0
WORKDIR /output
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
