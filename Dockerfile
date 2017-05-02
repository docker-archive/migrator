FROM alpine:3.5

RUN apk --no-cache add bash curl jq wget groff less python py-pip docker &&\
  pip install awscli &&\
  apk --purge -v del py-pip

COPY migrator.sh /usr/local/bin/migrator.sh

CMD ["/usr/local/bin/migrator.sh"]
