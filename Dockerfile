FROM hashicorp/vault:latest
USER root
RUN apk add --no-cache \
    jq curl wget bash vim git openssl ca-certificates \
    bind-tools netcat-openbsd \
    postgresql15-client mariadb-client redis \
    python3 py3-pip \
    && mkdir -p /vault/config /vault/data /vault/logs \
    && chown -R vault:vault /vault
USER vault
EXPOSE 8200
WORKDIR /vault
CMD ["vault", "server", "-dev", "-dev-listen-address=0.0.0.0:8200"]
