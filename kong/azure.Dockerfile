FROM kong:3.9

USER root

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl jq gettext-base ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY kong.azure.template.yaml /config/kong.azure.template.yaml
COPY start-kong.sh /usr/local/bin/start-kong.sh

RUN chmod +x /usr/local/bin/start-kong.sh

ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/tmp/kong.azure.yaml \
    KONG_PROXY_LISTEN=0.0.0.0:8000 \
    KONG_ADMIN_LISTEN=127.0.0.1:8001 \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_NGINX_PROXY_PROXY_BUFFERING=off \
    KONG_NGINX_PROXY_PROXY_CACHE=off \
    KONG_NGINX_PROXY_CHUNKED_TRANSFER_ENCODING=on \
    KONG_NGINX_PROXY_TCP_NODELAY=on \
    KONG_NGINX_PROXY_TCP_NOPUSH=on \
    KONG_NGINX_PROXY_KEEPALIVE_TIMEOUT=300 \
    KONG_NGINX_PROXY_PROXY_READ_TIMEOUT=600s \
    KONG_NGINX_PROXY_PROXY_SEND_TIMEOUT=600s

EXPOSE 8000

CMD ["bash", "/usr/local/bin/start-kong.sh"]
