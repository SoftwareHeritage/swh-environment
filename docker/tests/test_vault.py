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
    swhid = f"swh:1:dir:{dir_id}"

    # now cook it
    cook = apiget(f"vault/flat/{swhid}/", "POST")
    assert cook["swhid"] == swhid
    assert cook["fetch_url"].endswith(f"vault/flat/{swhid}/raw/")

    # while it's cooking, get the directory tree from the archive
    directory = getdirectory(dir_id)

    # retrieve the cooked tar file
    resp = pollapi(f"vault/flat/{swhid}/raw")
    tarf = tarfile.open(fileobj=io.BytesIO(resp.content))

    # and check the tarfile seems ok wrt. 'directory'
    assert tarf.getnames()[0] == swhid
    tarfiles = {t.name: t for t in tarf.getmembers()}

    for fname, fdesc in directory:
        tfinfo = tarfiles.get(join(swhid, fname))
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
        # XXX what to check for dir or rev?

    # check that if we ask a second time this directory, it returns the same
    # and does not cook it again
    recook = apiget(f"vault/flat/{swhid}/", "POST")
    assert recook["swhid"] == swhid
    assert recook["id"] == cook["id"]
    assert recook["status"] == "done"  # no need to wait for this to be true


def test_vault_git_bare(host, scheduler_host, git_origin, tmp_path, monkeypatch):
    # retrieve the revision of the master branch of the ingested git
    # repository (by the git_origin fixture)
    visit = apiget(f"origin/{quote_plus(git_origin)}/visit/latest")
    snapshot = apiget(f'snapshot/{visit["snapshot"]}')
    rev_id = snapshot["branches"]["refs/heads/master"]["target"]
    swhid = f"swh:1:rev:{rev_id}"
    revision = apiget(f"revision/{rev_id}")
    dir_id = revision["directory"]

    # now cook it
    cook = apiget(f"vault/git-bare/{swhid}/", "POST")
    assert cook["swhid"] == swhid
    assert cook["fetch_url"].endswith(f"vault/git-bare/{swhid}/raw/")

    # while it's cooking, get the directory tree from the archive
    directory = getdirectory(dir_id)

    # retrieve the cooked tar file
    resp = pollapi(f"vault/git-bare/{swhid}/raw")
    tarf = tarfile.open(fileobj=io.BytesIO(resp.content))
    assert tarf.getnames()[0] == f"{swhid}.git"

    # extract it in a tmp file and attempt to git clone it
    tarf.extractall(path=tmp_path)
    repo = tmp_path / "repo"
    host.run_test(f"git clone {tmp_path/swhid}.git {repo}")
    # check a few basic git stuff
    host.check_output(f"git -C {repo} branch") == "* master"
    host.check_output(f"git -C {repo} rev-parse HEAD") == rev_id
    host.run_test(f"git -C {repo} log")

    # check the working direcoty matches dir_id content from the archive
    for fname, fdesc in directory:
        if fdesc["type"] == "file":
            assert (repo / fname).is_file()
            if fdesc["perms"] == 0o120000:
                # it's a symlink; see DentryPerms in swh.model
                fdata = bytes((repo / fname).readlink())
            else:
                # it's an actual file
                fdata = (repo / fname).read_bytes()
            for algo in fdesc["checksums"]:
                if algo not in hashlib.algorithms_available:
                    continue
                hash = hashlib.new(algo, fdata).hexdigest()
                if hash != fdesc["checksums"][algo]:
                    breakpoint()
                assert (
                    hash == fdesc["checksums"][algo]
                ), f"File {fname}: {algo} mismatch"
        elif fdesc["type"] == "dir":
            assert (repo / fname).is_dir()
        elif fdesc["type"] == "rev":
            # TODO
            pass
        else:
            assert (
                False
            ), f"Unexpected directory entry type {fdesc['type']} from {fdesc}"

    # check that if we ask a second time this directory, it returns the same
    # and does not cook it again
    recook = apiget(f"vault/git-bare/{swhid}/", "POST")
    assert recook["swhid"] == swhid
    assert recook["id"] == cook["id"]
    assert recook["status"] == "done"  # no need to wait for this to be true
