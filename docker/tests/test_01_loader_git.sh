#!/bin/bash
shopt -s nullglob extglob

TEST_GIT_REPO_NAME="swh-loader-core"
TEST_GIT_REPO_URL="https://forge.softwareheritage.org/source/${TEST_GIT_REPO_NAME}.git"

status_message "Scheduling the loading of the git repository located at ${TEST_GIT_REPO_URL}"

docker-compose $DOCO_OPTIONS exec -T swh-scheduler swh scheduler task add load-git url=$TEST_GIT_REPO_URL

status_message "Waiting for the git loading task to complete"

wait_for_service_output 300 swh-loader "swh.loader.git.tasks.UpdateGitRepository.*succeeded"

status_message "The loading task has been successfully executed"

status_message "Getting all git objects contained in the repository"
git clone $TEST_GIT_REPO_URL
cd $TEST_GIT_REPO_NAME
cd "$(git rev-parse --git-path objects)"
for p in pack/pack-*([0-9a-f]).idx ; do
  git show-index < $p | cut -f 2 -d ' ' > $WORKDIR/git_objects
done
for o in [0-9a-f][0-9a-f]/*([0-9a-f]) ; do
  echo ${o/\/} >> $WORKDIR/git_objects
done

declare -ga CONTENTS
declare -ga DIRECTORIES
declare -ga REVISIONS
declare -ga RELEASES

while IFS='' read -r object || [[ -n "$object" ]]; do
  object_type=$(git cat-file -t $object)
  if [ "$object_type" = "blob" ]; then
    CONTENTS+=($object)
  elif [ "$object_type" = "tree" ]; then
    DIRECTORIES+=($object)
  elif [ "$object_type" = "commit" ]; then
    REVISIONS+=($object)
  elif [ "$object_type" = "tag" ]; then
    RELEASES+=($object)
  fi
done < $WORKDIR/git_objects

status_message "Checking all git objects have been successfully loaded into the archive"

status_message "Checking contents"
for content in "${CONTENTS[@]}"; do
  http_request_check GET ${SWH_WEB_API_BASEURL}/content/sha1_git:$content/
done
status_message "All contents have been successfully loaded into the archive"

status_message "Checking directories"
for directory in "${DIRECTORIES[@]}"; do
  http_request_check GET ${SWH_WEB_API_BASEURL}/directory/$directory/
done
status_message "All directories have been successfully loaded into the archive"

status_message "Checking revisions"
for revision in "${REVISIONS[@]}"; do
  http_request_check GET ${SWH_WEB_API_BASEURL}/revision/$revision/
done
status_message "All revisions have been successfully loaded into the archive"

status_message "Checking releases"
for release in "${RELEASES[@]}"; do
  http_request_check GET ${SWH_WEB_API_BASEURL}/release/$release/
done
status_message "All releases have been successfully loaded into the archive"
