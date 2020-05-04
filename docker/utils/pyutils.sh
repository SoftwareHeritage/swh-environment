#!/bin/bash

setup_pip () {
  echo Using pip from $(which pip)

  if [[ -d /src ]] ; then
    tmpdir=`mktemp -d`
    # Source directories might not be writeable, but building them writes
    # in-tree; so we're copying them to a location guaranteed to be writeable.
    rsync -a /src/ $tmpdir/ --exclude "*/__pycache__/" --exclude "*/.tox/" --exclude "*/.hypothesis/"
    for srcrepo in $tmpdir/swh-* ; do
      pip install $srcrepo
    done
    rm -rf $tmpdir
  fi

  echo Installed Python packages:
  pip list
}
