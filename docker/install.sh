#!/bin/bash -Eeu

apk --update add --virtual build-dependencies build-base
gem install simplecov simplecov-console hirb benchmark --no-document
apk del build-dependencies build-base
rm -vrf /var/cache/apk/*

# Records the Ruby this image holds, in the shape every image shares. The
# installed interpreter is asked, so the version is one the image can run
# rather than one written down when someone last edited this file.
readonly LANGUAGE_VERSION=$(ruby -e 'print RUBY_VERSION')

if [ -z "${LANGUAGE_VERSION}" ]; then
  echo 'Could not read a version from RUBY_VERSION' >&2
  exit 1
fi

cat > /versions.json <<EOF
{
  "language": {
    "name": "Ruby",
    "version": "${LANGUAGE_VERSION}"
  },
  "test_frameworks": []
}
EOF
