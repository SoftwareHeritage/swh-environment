#!/bin/bash

setup_pip () {
  echo Using pip from $(which pip)

  if [[ -d /src ]] ; then
    tmpdir=`mktemp -d`
    pushd /src
    for srcrepo in swh-* ; do
      if [ ! -w $srcrepo ]; then
        echo "$srcrepo is read-only; install from a local copy"
        # Source directories might not be writeable, but building them writes
        # in-tree; so we're copying them to a location guaranteed to be writeable.
        rsync -a --chmod=+w $srcrepo $tmpdir/ --exclude "*/__pycache__/" --exclude "*/.tox/" --exclude "*/.hypothesis/"
        pushd $tmpdir/$srcrepo
      else
        pushd $srcrepo
      fi
      # Install package in editable mode if source directory is writable
      pip install -e .
      # swh-web special case to handle frontend assets compilation
      if [ -f package.json ]; then
        yarn install --frozen-lockfile
        if [ ! -w . ]; then
          # swh-web source directory is not writable, there is no interest to
          # use webpack-dev-server as we made a copy of assets source files,
          # simply compile the assets then
          yarn build-dev
        else
          # webpack-dev-server can be used, web application will be automatically
          # reloaded in the browser when modifying assets sources (js, css, ...)
          yarn start-dev&
        fi
      fi
      popd
    done
    popd
  fi

  echo Installed Python packages:
  pip list
}
