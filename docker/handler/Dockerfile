FROM golang:1.23-alpine AS builder
COPY dns-proxy/ /src/
RUN cd /src && CGO_ENABLED=0 go build -o /dns-proxy .

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    nftables \
    iproute2 \
    dnsutils \
    openssl \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install mitmproxy --break-system-packages

RUN mkdir -p /etc/membrane

COPY --from=builder /dns-proxy /usr/local/bin/dns-proxy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
