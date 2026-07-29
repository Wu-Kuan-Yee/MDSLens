FROM alpine:3.22 AS certificates

FROM ubuntu:24.04

ARG MDSLENS_VERSION=development
LABEL org.opencontainers.image.title="MDSLens Web Gateway" \
      org.opencontainers.image.description="MDSLens Web/PWA and its same-origin gateway" \
      org.opencontainers.image.source="https://github.com/Wu-Kuan-Yee/MDSLens" \
      org.opencontainers.image.version="${MDSLENS_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

COPY --from=certificates /etc/ssl/certs/ca-certificates.crt \
  /etc/ssl/certs/ca-certificates.crt

RUN groupadd --gid 65532 mdslens \
    && useradd --uid 65532 --gid 65532 --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin mdslens

WORKDIR /app
COPY --chown=65532:65532 mdslens-web-gateway /app/mdslens-web-gateway
COPY --chown=65532:65532 web /app/web

USER 65532:65532
ENV MDSLENS_WEB_BIND=0.0.0.0:8088 \
    MDSLENS_WEB_ROOT=/app/web \
    MDSLENS_WEB_SECURE_COOKIE=1
EXPOSE 8088

ENTRYPOINT ["/app/mdslens-web-gateway"]
