#!/bin/bash

usage() {
    echo "Usage: $0 [-b|--build] [-u|--upload] SWH_PACKAGE"
    echo "E.g.: make-package -b swh-core"
    exit 1
}

# command line parsing

build="no"
upload="no"
package=""
while (( "$#" )); do
    case "$1" in
	-b|--build) build="yes" ;;
	-u|--upload) upload="yes" ;;
	*) package="$1";;
    esac
    shift
done
if [ "$build,$upload" = "no,no" -o -z "$package" ] ; then
    usage
fi

set -ex

CURDIR=$(readlink -f "$package")
BASENAME="$(basename "$CURDIR")"
MODULE="${BASENAME//-/.}"

REPOSITORY=http://debian.internal.softwareheritage.org/

DESTINATION=pergamon.internal.softwareheritage.org
DESTDIR=/srv/softwareheritage/repository

TEMP=$(mktemp -d)

trap "{ rm -rf $TEMP; }" EXIT

cd "$CURDIR"

VERSION=$(git describe | sed s/^v//)

if [ "$build" = "yes" ] ; then
    # Generate source tarball and put it in the right place
    python3 setup.py sdist -d $TEMP
    mv $TEMP/$MODULE-$VERSION.tar.gz $TEMP/${BASENAME}_${VERSION}.orig.tar.gz

    # Extract source tarball and overlay Debian packaging
    cd $TEMP
    tar xf ${BASENAME}_${VERSION}.orig.tar.gz
    mv $MODULE-$VERSION $BASENAME-$VERSION
    cd $BASENAME-$VERSION
    cp -r $CURDIR/debian .

    # Generate changelog for unstable
    dch -v "${VERSION}-1" "Deploy ${VERSION}"
    dch --force-distribution --distribution unstable-swh -r ""

    # Build unstable package with original source
    sbuild -As --force-orig-source --extra-repository="deb [trusted=yes] ${REPOSITORY} unstable main"

    # Sign and send unstable package
    CHANGES_FILE=../${BASENAME}_${VERSION}-1_amd64.changes
    debsign ${CHANGES_FILE}
fi

if [ "$upload" = "yes" ] ; then
    dcmd scp ${CHANGES_FILE} ${DESTINATION}:${DESTDIR}/incoming
    ssh ${DESTINATION} reprepro -vb ${DESTDIR} processincoming incoming
fi

if [ "$build" = "yes" ] ; then
    # Generate changelog for backports
    dch -l ~bpo8~swh+ "Rebuild for jessie-backports-swh"
    dch -r --distribution jessie-backports-swh --force-distribution ""

    # Build backport package
    sbuild -As --extra-repository="deb [trusted=yes] ${REPOSITORY} jessie main"

    # Sign and send backports package
    CHANGES_FILE=../${BASENAME}_${VERSION}-1~bpo8~swh+1_amd64.changes
    debsign ${CHANGES_FILE}
fi

if [ "$upload" = "yes" ] ; then
    dcmd scp ${CHANGES_FILE} ${DESTINATION}:${DESTDIR}/incoming
    ssh ${DESTINATION} reprepro -vb ${DESTDIR} processincoming incoming
fi
