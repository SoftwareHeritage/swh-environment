#!/bin/bash

setup_pip () {
	export PATH=${HOME}/.local/bin:${PATH}

	if [[ -d /src ]] ; then
    for srcrepo in /src/swh-* ; do
        pip install -e $srcrepo
    done
  fi

  echo Installed Python packages:
  pip list

}
