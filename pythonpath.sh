# usage: . pythonpath
#
# source this file as above (do not execute it) to set the PYTHONPATH
# environment variable to the list of directories corresponding to the
# repositories known to mr

path=$(
    for dir in $(bin/list-repos --absolute) ; do
	if echo "$dir" | grep -q -- '-template$' ; then
	    continue
	fi
	if test -f "${dir}/swh/__init__.py" ; then
	    echo "$dir"
	fi
    done \
	| paste -d':' -s)

export PYTHONPATH="$path"
