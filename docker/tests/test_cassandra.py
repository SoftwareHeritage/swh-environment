# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import re
from typing import List

import pytest

from .conftest import compose_host_for_service
from .test_git_loader import test_git_loader  # noqa


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    # overload the default list to add cassandra specific compose override
    return ["docker-compose.yml", "docker-compose.cassandra.yml"]


@pytest.fixture(scope="module")
def docker_compose(request, docker_compose):
    # to make sure tests are not using the pg db as backend somehow, since we
    # cannot easily "remove" the swh-storage-db dependency from the swh-storage
    # declaration, we have to manually stop and remove it.
    print("Stopping swh-storage-db")
    docker_compose.check_compose_output("stop swh-storage-db")
    docker_compose.check_compose_output("rm swh-storage-db")
    print("swh-storage-db service deleted")
    yield docker_compose


def test_ensure_cassandra(docker_compose, origins):
    check_output = docker_compose.check_compose_output
    # ensure the cassandra-seed service is running
    assert check_output("ps -q cassandra-seed")
    # ensure the swh-storage-db service is NOT running
    assert not check_output("ps -q swh-storage-db")
    cass_host = compose_host_for_service(docker_compose, "cassandra-seed")
    assert cass_host

    # check we do have some archived content in cassandra
    orig_resp = cass_host.check_output("cqlsh -e 'SELECT url FROM swh.origin;'")
    origs = {url.strip() for url in orig_resp.strip().splitlines()[2:-1]}
    missing_origins = {url for _, url in origins} - origs
    assert not missing_origins, origs

    for otype in (
        "origin",
        "origin_visit",
        "origin_visit_status",
        "content",
        "directory",
        "revision",
        "release",
        "snapshot",
    ):
        objs = cass_host.check_output(f"cqlsh -e 'SELECT * FROM swh.{otype};'")
        m = re.match(r"\((?P<rows>\d+) rows\)", objs.splitlines()[-1])
        assert m, objs
        assert int(m.group("rows"))
