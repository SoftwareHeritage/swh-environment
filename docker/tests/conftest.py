# Copyright (C) 2019-2021  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import re
import time
from typing import List, Tuple
from uuid import uuid4 as uuid

import pytest
import testinfra

APIURL = "http://localhost:5080/api/1/"


# wait-for-it timeout
WFI_TIMEOUT = 120


@pytest.fixture(scope="module")
def docker_host():
    return testinfra.get_host("local://")


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    # this fixture is meant to be overloaded in test modules to include the
    # required compose files for the test (see test_deposit.py for example)
    return ["docker-compose.yml"]


@pytest.fixture(scope="module")
def project_name() -> str:
    return f"swh_test_{uuid()}"


@pytest.fixture(scope="module")
def api_url() -> str:
    return APIURL


@pytest.fixture(scope="module")
def compose_cmd(docker_host, project_name, compose_files):

    print(f"compose project is {project_name}")
    compose_file_cmd = "".join(f" -f {fname} " for fname in compose_files)
    try:
        docker_host.check_output("docker compose version")
        return f"docker compose -p {project_name} {compose_file_cmd} "
    except AssertionError:
        print("Fall back to old docker-compose command")
        return f"docker-compose -p {project_name} {compose_file_cmd} "


# scope='module' so we use the same container for all the tests in a test file
@pytest.fixture(scope="module")
def docker_compose(request, docker_host, project_name, compose_cmd):
    print(f"Starting the compose session {project_name}...", end=" ", flush=True)
    try:
        # start the whole cluster
        docker_host.check_output(f"{compose_cmd} up -d")
        print("OK")

        # small hack: add a helper func to docker_host; so it's not necessary to
        # use all 3 docker_compose, docker_host and compose_cmd fixtures everywhere
        docker_host.check_compose_output = lambda command: docker_host.check_output(
            f"{compose_cmd} {command}"
        )
        yield docker_host
    finally:
        print(f"\nStopping the compose session {project_name}...", end=" ", flush=True)
        # first kill all the containers (brutal but much faster than a proper shutdown)
        containers = docker_host.check_output(f"{compose_cmd} ps -q").replace("\n", " ")
        docker_host.check_output(f"docker kill {containers}")
        # and gently stop the cluster
        docker_host.check_output(f"{compose_cmd} down --volumes --remove-orphans")
        print("OK")
        for _ in range(30):
            if not docker_host.check_output(f"{compose_cmd} ps -q"):
                print("... All the services are stopped")
                break
            time.sleep(1)
        else:
            assert not docker_host.check_output(
                f"{compose_cmd} ps -q"
            ), "Failed to shut compose down"


@pytest.fixture(scope="module")
def scheduler_host(request, docker_compose):
    # run a container in which test commands are executed
    docker_id = docker_compose.check_compose_output(
        "run -d swh-scheduler shell sleep 1h"
    ).strip()
    scheduler_host = testinfra.get_host("docker://" + docker_id)
    scheduler_host.check_output(f"wait-for-it swh-scheduler:5008 -t {WFI_TIMEOUT}")
    scheduler_host.check_output(f"wait-for-it swh-storage:5002 -t {WFI_TIMEOUT}")

    # return a testinfra connection to the container
    yield scheduler_host

    # at the end of the test suite, destroy the container
    docker_compose.check_output(f"docker rm -f {docker_id}")


@pytest.fixture(scope="module")
def origin_urls() -> List[Tuple[str, str]]:
    # This fixture is meant to be overloaded in test modules to initialize the
    # main storage with the content from the loading of the origins listed
    # here. By default we only load one git origin (to try to keep execution
    # time under control), but some tests may require more than that.
    return [("git", "https://gitlab.softwareheritage.org/swh/devel/swh-core.git")]


@pytest.fixture(scope="module")
def origins(docker_compose, scheduler_host, origin_urls: List[Tuple[str, str]]):
    """A fixture that ingest origins from origin_urls in the storage

    For each origin url listed in origin_urls, scheduler a loading task and
    wait for all the loading tasks to finish. Check these are in the 'eventful'
    state.
    """
    task_ids = {}
    if len(origin_urls) > 1:
        # spawn a few loaders to try to speed things up a bit
        docker_compose.check_compose_output("up -d --no-recreate --scale swh-loader=4")

    for origin_type, origin_url in origin_urls:
        print(f"Scheduling {origin_type} loading task for {origin_url}")
        task = scheduler_host.check_output(
            f"swh scheduler task add load-{origin_type} url={origin_url}"
        )
        m = re.search(r"^Task (?P<id>\d+)$", task, flags=re.MULTILINE)
        assert m
        taskid = m.group("id")
        assert int(taskid) > 0
        task_ids[origin_url] = taskid

    for _, origin_url in origin_urls:
        taskid = task_ids[origin_url]
        for _ in range(120):
            status = scheduler_host.check_output(
                f"swh scheduler task list --list-runs --task-id {taskid}"
            )
            if "Executions:" in status:
                if "[eventful]" in status:
                    break
                if "[started]" in status or "[scheduled]" in status:
                    time.sleep(1)
                    continue
                if "[failed]" in status:
                    loader_logs = docker_compose.check_compose_output("logs swh-loader")
                    raise AssertionError(
                        "Loading execution failed\n"
                        f"status: {status}\n"
                        f"loader logs: " + loader_logs
                    )
                raise AssertionError(
                    f"Loading execution failed, task status is {status}"
                )
    return origin_urls
