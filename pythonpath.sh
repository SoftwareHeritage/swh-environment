# usage: . pythonpath
#
# source this file as above (do not execute it) to set the PYTHONPATH
# environment variable to the list of directories corresponding to the
# repositories known to mr

base_path=$( dirname "$0" )

tmp_path=$(
for dir in $( builtin cd $base_path && bin/ls-all-repos --absolute ) ; do
    if echo "$dir" | grep -q -- '-template$' ; then
        continue
    fi
    if test -d "${dir}/swh/" ; then
        echo "$dir"
    fi
done \
    | paste -d':' -s)

export PYTHONPATH="$tmp_path"

if [ "$1" = "-p" -o "$1" = "--print" ] ; then
    echo $PYTHONPATH
fi
