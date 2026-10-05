FROM gns3/ubuntu:resolute
RUN apt-get update \
 && apt-get install -y --no-install-recommends iptables iproute2 iputils-ping \
 && rm -rf /var/lib/apt/lists/*
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
CMD ["/usr/local/bin/entrypoint.sh"]
