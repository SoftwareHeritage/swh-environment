# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import dataclasses
import hashlib
import time
from typing import Iterable, List, Tuple

import pytest
import requests
import testinfra
import yaml


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    return ["docker-compose.yml", "docker-compose.alter.yml"]


@pytest.fixture(scope="module")
def compose_services() -> List[str]:
    return [
        "swh-alter",
        "swh-storage",
        "swh-storage-replayer",
        "swh-scheduler-runner",
        "swh-scheduler-listener",
        "swh-scheduler-schedule-recurrent",
        "swh-web",
        "swh-loader",
        "swh-lister",
    ]


@pytest.fixture(scope="module")
def origin_urls() -> List[Tuple[str, str]]:
    return [
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-py-template.git"),
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-alter.git"),
    ]


@pytest.fixture(scope="module")
def alter_host(docker_compose) -> Iterable[testinfra.host.Host]:
    # Getting a compressed graph with swh-graph is not stable enough
    # so we use a mock server for the time being that starts
    # by default when running the swh-alter container.
    docker_services = docker_compose.check_compose_output(
        "ps --status running --format '{{.Service}} {{.Name}}'"
    )
    docker_id = dict(line.split(" ") for line in docker_services.split("\n"))[
        "swh-alter"
    ]
    host = testinfra.get_host("docker://" + docker_id)
    host.check_output("wait-for-it --timeout=60 swh-alter:5009")
    yield host


@pytest.fixture(scope="module")
def verified_origins(alter_host, docker_compose, origins, kafka_api_url):
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

    # wait until the replayer is done
    print("Waiting for the replayer to be done")
    cluster = requests.get(kafka_api_url).json()["data"][0]["cluster_id"]

    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-kafka --presence {' '.join(origin_swhids)}"
    )

    def kget(path):
        url = f"{kafka_api_url}/{cluster}/{path}"
        resp = requests.get(url)
        if resp.status_code == 200:
            return resp.json()
        resp.raise_for_status()

    for _ in range(30):
        try:
            lag_sum = kget("consumer-groups/swh.storage.alter.replayer/lag-summary")
        except requests.exceptions.HTTPError as exc:
            print(f"Failed to retrieve consumer status: {exc}")
        else:
            if lag_sum["total_lag"] == 0:
                break
        time.sleep(1)
    else:
        raise AssertionError(
            "Could not detect a condition where the replayer did its job"
        )
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


def test_fork_removed_in_kafka(docker_compose, fork_removed):
    # Ensure the SWHIDs have been removed from Kafka
    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-kafka {' '.join(fork_removed.removed_swhids)}"
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


def test_fork_restored_in_kafka(docker_compose, fork_restored):
    # Ensure the SWHIDs are back in Kafka
    docker_compose.check_compose_output(
        "exec swh-alter python /src/alter_companion.py "
        f"query-kafka --presence {' '.join(fork_restored.removed_swhids)}"
    )
