# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import dataclasses
import hashlib
import time
from typing import Iterable, List, Tuple

import pytest
import testinfra
import yaml


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    return ["docker-compose.yml", "docker-compose.alter.yml"]


@pytest.fixture(scope="module")
def origin_urls() -> List[Tuple[str, str]]:
    return [
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-py-template.git"),
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-alter.git"),
    ]


@pytest.fixture(scope="module")
def alter_host(docker_host, compose_cmd) -> Iterable[testinfra.host.Host]:
    print(docker_host.check_output(f"{compose_cmd} logs swh-alter"))
    # Getting a compressed graph with swh-graph is not stable enough
    # so we use a mock server for the time being that starts
    # by default when running the swh-alter container.
    docker_services = docker_host.check_output(
        f"{compose_cmd} ps --status running --format " "'{{.Service}} {{.Name}}'"
    )
    print(docker_services)
    docker_id = dict(line.split(" ") for line in docker_services.split("\n"))[
        "swh-alter"
    ]
    host = testinfra.get_host("docker://" + docker_id)
    host.check_output("wait-for-it --timeout=60 swh-alter:5009")
    yield host


@pytest.fixture(scope="module")
def verified_origins(alter_host, docker_compose, origins):
    # Verify that our origins have properly been loaded in PostgreSQL
    # and Cassandra
    origin_swhids = {
        f"swh:1:ori:{hashlib.sha1(url.encode('us-ascii')).hexdigest()}"
        for _, url in origins
    }
    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-postgresql --presence {' '.join(origin_swhids)}"
    )
    # Let’s give the replayer some time to catch up
    tries = 0
    while True:
        try:
            docker_compose.check_compose_output(
                "exec swh-alter python /src/alter_companion.py "
                f"query-cassandra --presence {' '.join(origin_swhids)}"
            )
            break
        except AssertionError:
            tries += 1
            if tries > 3:
                raise
            time.sleep(1)

    return origins


@dataclasses.dataclass
class RemovalOperation:
    identifier: str
    bundle_path: str
    origins: List[str]
    removed_swhids: List[str] = dataclasses.field(default_factory=list)

    def run_in(self, host):
        remove_output = host.check_output(
            "echo y | swh alter remove "
            f"--identifier '{self.identifier}' "
            f"--recovery-bundle '{self.bundle_path}' "
            f"{' '.join(self.origins)}"
        )
        print(remove_output)
        dump = host.check_output(
            f"swh alter recovery-bundle info --dump-manifest '{self.bundle_path}'"
        )
        manifest = yaml.safe_load(dump)
        self.removed_swhids = manifest["swhids"]


FORK_REMOVAL_OP = RemovalOperation(
    identifier="integration-test-01",
    bundle_path="/tmp/integration-test-01.swh-recovery-bundle",
    origins=["https://gitlab.softwareheritage.org/swh/devel/swh-alter.git"],
)


@pytest.fixture(scope="module")
def fork_removed(alter_host, verified_origins):
    FORK_REMOVAL_OP.run_in(alter_host)
    assert len(FORK_REMOVAL_OP.removed_swhids) > 0
    return FORK_REMOVAL_OP


def test_fork_removed_in_postgresql(docker_compose, fork_removed):
    # Ensure the SWHIDs have been removed from PostgreSQL
    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-postgresql {' '.join(fork_removed.removed_swhids)}"
    )


def test_fork_removed_in_cassandra(docker_compose, fork_removed):
    # Ensure the SWHIDs have been removed from Cassandra
    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-cassandra {' '.join(fork_removed.removed_swhids)}"
    )


@pytest.fixture(scope="module")
def fork_restored(fork_removed, alter_host):
    alter_host.check_output(
        f"swh alter recovery-bundle restore '{fork_removed.bundle_path}' "
        "--identity /age-identities.txt"
    )
    return fork_removed


def test_fork_restored_in_postgresql(docker_compose, fork_restored):
    # Ensure the SWHIDs are back in PostgreSQL
    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-postgresql --presence {' '.join(fork_restored.removed_swhids)}"
    )


def test_fork_restored_in_cassandra(docker_compose, fork_restored):
    # Ensure the SWHIDs are back in Cassandra
    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-cassandra --presence {' '.join(fork_restored.removed_swhids)}"
    )
