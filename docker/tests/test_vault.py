# Copyright (C) 2019-2021  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import hashlib
import io
from os.path import join
import tarfile
from urllib.parse import quote_plus

from .conftest import apiget, getdirectory, pollapi


def test_vault_directory(scheduler_host, git_origin):
    # retrieve the root directory of the master branch of the ingested git
    # repository (by the git_origin fixture)
    visit = apiget(f"origin/{quote_plus(git_origin)}/visit/latest")
    snapshot = apiget(f'snapshot/{visit["snapshot"]}')
    rev_id = snapshot["branches"]["refs/heads/master"]["target"]
    revision = apiget(f"revision/{rev_id}")
    dir_id = revision["directory"]

    # now cook it
    cook = apiget(f"vault/directory/{dir_id}/", "POST")
    assert cook["obj_type"] == "directory"
    assert cook["obj_id"] == dir_id
    assert cook["fetch_url"].endswith(f"vault/directory/{dir_id}/raw/")

    # while it's cooking, get the directory tree from the archive
    directory = getdirectory(dir_id)

    # retrieve the cooked tar file
    resp = pollapi(f"vault/directory/{dir_id}/raw")
    tarf = tarfile.open(fileobj=io.BytesIO(resp.content))

    # and check the tarfile seems ok wrt. 'directory'
    assert tarf.getnames()[0] == dir_id
    tarfiles = {t.name: t for t in tarf.getmembers()}

    for fname, fdesc in directory:
        tfinfo = tarfiles.get(join(dir_id, fname))
        assert tfinfo, f"Missing path {fname} in retrieved tarfile"
        if fdesc["type"] == "file":
            if tfinfo.issym():
                # checksum was computed from targeted path for symlink
                fdata = tfinfo.linkname.encode()
            else:
                # symlink has no size in tar archive so this test fails
                assert fdesc["length"] == tfinfo.size, f"File {fname}: length mismatch"
                fdata = tarf.extractfile(tfinfo).read()

            for algo in fdesc["checksums"]:
                if algo not in hashlib.algorithms_available:
                    continue
                hash = hashlib.new(algo, fdata).hexdigest()
                assert (
                    hash == fdesc["checksums"][algo]
                ), f"File {fname}: {algo} mismatch"
        # XXX what to check for dir? symlink? (other?)

    # check that if we ask a second time this directory, it returns the same
    # and does not cook it again
    recook = apiget(f"vault/directory/{dir_id}/", "POST")
    assert recook["obj_type"] == "directory"
    assert recook["obj_id"] == dir_id
    assert recook["id"] == cook["id"]
    assert recook["status"] == "done"  # no need to wait for this to be true
