FROM alpine:3.5

RUN apk --no-cache add bash curl jq wget groff less python py-pip &&\
  pip install awscli &&\
  apk --purge -v del py-pip

### use docker-1.6.2; upgrading will break password decryption
COPY docker-1.6.2 /usr/bin/docker

COPY migrator.sh /usr/local/bin/migrator.sh

CMD ["/usr/local/bin/migrator.sh"]
