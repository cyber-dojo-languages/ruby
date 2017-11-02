FROM  ruby:2.4.1-alpine3.6
LABEL maintainer=jon@jaggersoft.com

RUN ruby --version | grep -q 2.4.1

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# install tini (for pid 1 zombie reaping)
RUN apk add --update --repository http://dl-cdn.alpinelinux.org/alpine/edge/community/ tini
ENTRYPOINT [ "/sbin/tini", "--" ]
