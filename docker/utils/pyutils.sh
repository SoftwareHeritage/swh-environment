#!/bin/sh

setup_pip() {
  echo Using pip from $(which pip)

  if [ -d /src ] ; then
    echo "Found /src, installing python packages from sources"
    tmpdir=`mktemp -d`
    find /src -maxdepth 1 -name 'swh-*' -type d | while read srcrepo; do
      pushd $srcrepo
      # Install package in editable mode if source directory is writable
      pip install -e .
      popd
    done

    echo "Installed Python packages:"
    pip list
  else
    # cat the existing pip list file, save a few seconds...
    echo "Installed Python packages:"
    cat  /srv/softwareheritage/pip-installed.txt
  fi
}
