#!/bin/bash


setup_pip () {
  echo Using pip from $(which pip)

  if [[ -d /src ]] ; then
    tmpdir=`mktemp -d`
    pushd /src
    for srcrepo in swh-* ; do
      if [ -w $srcrepo ]
      then
        # Install package in editable mode if source directory is writable
        pip install -e $srcrepo
      else
        # Source directories might not be writeable, but building them writes
        # in-tree; so we're copying them to a location guaranteed to be writeable.
        rsync -a --chmod=+w $srcrepo $tmpdir/ --exclude "*/__pycache__/" --exclude "*/.tox/" --exclude "*/.hypothesis/"
        pip install $tmpdir/$srcrepo
      fi
    done
    popd
    rm -rf $tmpdir
  fi

  echo Installed Python packages:
  pip list
}
