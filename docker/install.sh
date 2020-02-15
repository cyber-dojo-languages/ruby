#!/bin/bash -Eeu

apk --update add --virtual build-dependencies build-base
gem install simplecov simplecov-console hirb --no-document
apk del build-dependencies build-base
rm -vrf /var/cache/apk/*
