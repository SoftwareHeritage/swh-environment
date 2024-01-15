# Copyright (C) 2019-2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

from urllib.parse import quote_plus

from dulwich import porcelain
from dulwich.repo import MemoryRepo

from .utils import grouper


def test_git_loader(scheduler_host, origins, api_get):
    # check the loaded repos from origins are OK, and nothing is missing
    for origin_type, url in origins:
        assert origin_type == "git"
        print(f"Retrieve references available at {url}")
        repo = MemoryRepo()
        gitrefs = porcelain.fetch(repo, url).refs

        print(f"Look for origin {url}")
        # use quote_plus to prevent urljoin from messing with the 'http://' part of
        # the url
        origin = api_get(f"origin/{quote_plus(url)}/get/")
        assert origin["url"] == url

        visit = api_get(f"origin/{quote_plus(url)}/visit/latest/")
        assert visit["status"] == "full"

        print("Check every identified git ref has been loaded")
        snapshot = api_get(f'snapshot/{visit["snapshot"]}/')

        branches = snapshot["branches"]

        while snapshot["next_branch"] is not None:
            snapshot = api_get(
                f'snapshot/{visit["snapshot"]}/?branches_from={snapshot["next_branch"]}'
            )
            branches.update(snapshot["branches"])

        print(f"snapshot has {len(branches)} branches")

        # check every fetched branch is present in the snapshot
        for branch_name, rev in gitrefs.items():
            # for tags, only check for final revision id
            if branch_name.startswith(b"refs/tags/") and not branch_name.endswith(
                b"^{}"
            ):
                continue
            rev_desc = api_get(f"revision/{rev.decode()}/")
            assert rev_desc["type"] == "git"

        tag_revision = {}
        tag_release = {}
        for tag, rev in gitrefs.items():
            if tag.startswith(b"refs/tags/"):
                tag_str = tag.decode()
                rev_str = rev.decode()
                if tag.endswith(b"^{}"):
                    tag_revision[tag_str[:-3]] = rev_str
                else:
                    tag_release[tag_str] = rev_str

        for tag, revision in tag_revision.items():
            # check that every release tag listed in the snapshot is known by the
            # archive and consistent
            release_id = tag_release[tag]
            release = api_get(f"release/{release_id}/")
            assert release["id"] == release_id
            assert release["target_type"] == "revision"
            assert release["target"] == revision
            # and compare this with what git ls-remote reported
            tag_desc = branches[tag]
            assert tag_desc["target_type"] == "release"
            assert tag_desc["target"] == release_id

        print("Check every git object is known by the archive")
        for batch in grouper(repo.object_store, 1000):
            swhids = []
            for sha1 in batch:
                obj = repo.get_object(sha1)
                sha1_str = sha1.decode()
                if obj.type_name == b"blob":
                    swhids.append(f"swh:1:cnt:{sha1_str}")
                elif obj.type_name == b"commit":
                    swhids.append(f"swh:1:rev:{sha1_str}")
                elif obj.type_name == b"tree":
                    swhids.append(f"swh:1:dir:{sha1_str}")
                elif obj.type_name == b"tag":
                    swhids.append(f"swh:1:rel:{sha1_str}")
            known = api_get("known/", verb="post", json=swhids)
            assert all(v["known"] for k, v in known.items())
