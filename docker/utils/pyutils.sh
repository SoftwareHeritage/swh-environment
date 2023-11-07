#!/bin/sh

setup_pip() {
  echo Using pip from $(which pip)

  if [ -d /src ] ; then
    tmpdir=`mktemp -d`
    find /src -maxdepth 1 -name 'swh-*' -type d | while read srcrepo; do
      pushd $srcrepo
      # Install package in editable mode if source directory is writable
      pip install -e .
      popd
    done
  fi

  echo Installed Python packages:
  pip list
}
