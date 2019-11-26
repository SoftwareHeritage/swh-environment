#!/bin/bash

setup_pip () {
  echo Using pip from $(which pip)

  if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
      pip install $srcrepo
    done
  fi

  echo Installed Python packages:
  pip list
}
