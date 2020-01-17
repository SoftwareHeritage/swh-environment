# Copyright (C) 2019-2020  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

from urllib.parse import quote_plus

from .conftest import apiget


def test_git_loader(scheduler_host, git_origin):
    url = git_origin

    print(f'Retrieve references available at {url}')
    gitrefs = scheduler_host.check_output(f'git ls-remote {url}')
    gitrefs = [x.split() for x in gitrefs.splitlines()]

    print(f'Look for origin {url}')
    # use quote_plus to prevent urljoin from messing with the 'http://' part of
    # the url
    origin = apiget(f'origin/{quote_plus(url)}/get')
    assert origin['url'] == url

    visit = apiget(f'origin/{quote_plus(url)}/visit/latest')
    assert visit['status'] == 'full'

    print(f'Check every identified git ref has been loaded')
    snapshot = apiget(f'snapshot/{visit["snapshot"]}')

    print(f'snapshot has {len(snapshot["branches"])} branches')
    branches = snapshot["branches"]

    # check every branch reported by git ls-remote is present in the snapshot
    for rev, branch_name in gitrefs:
        # for tags, only check for final revision id
        if branch_name.startswith('refs/tags/') \
           and not branch_name.endswith('^{}'):
            continue
        rev_desc = apiget(f'revision/{rev}')
        assert rev_desc['type'] == 'git'

    tag_revision = {}
    tag_release = {}
    for rev, tag in gitrefs:
        if tag.startswith('refs/tags/'):
            if tag.endswith('^{}'):
                tag_revision[tag[:-3]] = rev
            else:
                tag_release[tag] = rev

    for tag, revision in tag_revision.items():
        # check that every release tag listed in the snapshot is known by the
        # archive and consistant
        release_id = tag_release[tag]
        release = apiget(f'release/{release_id}')
        assert release['id'] == release_id
        assert release['target_type'] == 'revision'
        assert release['target'] == revision
        # and compare this with what git ls-remote reported
        tag_desc = branches[tag]
        assert tag_desc['target_type'] == 'release'
        assert tag_desc['target'] == release_id
