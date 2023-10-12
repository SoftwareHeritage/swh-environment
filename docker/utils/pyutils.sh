#!/bin/bash

setup_pip () {
  echo Using pip from $(which pip)

  if [[ -d /src ]] ; then
    tmpdir=`mktemp -d`
    pushd /src
    for srcrepo in swh-* ; do
      pushd $srcrepo
      # Install package in editable mode if source directory is writable
      pip install -e .
      popd
    done
    popd
  fi

  echo Installed Python packages:
  pip list
}
