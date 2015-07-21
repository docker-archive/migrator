FROM debian:jessie

RUN (apt-get update &&\
  apt-get install -y curl wget jq)
RUN (wget "https://get.docker.com/builds/Linux/x86_64/docker-1.6.2" -O /usr/bin/docker &&\
  chmod +x /usr/bin/docker)
ADD migrate.sh /usr/local/bin/migrate.sh

ENTRYPOINT ["/usr/local/bin/migrate.sh"]
CMD [""]
