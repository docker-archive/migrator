FROM debian:jessie

RUN (apt-get update &&\
  apt-get install -y curl wget jq)
### use docker-1.6.2; upgrading will break password decryption
RUN (wget "https://get.docker.com/builds/Linux/x86_64/docker-1.6.2" -O /usr/bin/docker &&\
  chmod +x /usr/bin/docker)
ADD migrator.sh /usr/local/bin/migrator.sh

ENTRYPOINT ["/usr/local/bin/migrator.sh"]
CMD [""]
