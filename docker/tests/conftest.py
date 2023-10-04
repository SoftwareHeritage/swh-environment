# Copyright (C) 2019-2021  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

from os.path import join
import re
import time
from typing import Generator, List, Mapping, Tuple
from urllib.parse import urljoin
from uuid import uuid4 as uuid

import pytest
import requests
import testinfra

APIURL = "http://127.0.0.1:5080/api/1/"


# wait-for-it timeout
WFI_TIMEOUT = 120


@pytest.fixture(scope="module")
def docker_host():
    return testinfra.get_host("local://")


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    return ["docker-compose.yml"]


@pytest.fixture(scope="module")
def project_name() -> str:
    return f"swh_test_{uuid()}"


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
        docker_host.check_output(f"{compose_cmd} down -v")
        print("OK")
        for i in range(30):
            if not docker_host.check_output(f"{compose_cmd} ps -q"):
                print("... All the services are stopped")
                break
            time.sleep(1)
        else:
            breakpoint()
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
    return [("git", "https://gitlab.softwareheritage.org/swh/devel/swh-core.git")]


@pytest.fixture(scope="module")
def origins(docker_compose, scheduler_host, origin_urls: List[Tuple[str, str]]):
    """A fixture that ingest origins from origin_urls in the storage

    For each origin url listed in origin_urls, scheduler a loading task and
    wait for all the loading tasks to finish. Check these are in the 'eventful'
    state.
    """
    for origin_type, origin_url in origin_urls:
        print(f"Scheduling {origin_type} loading task for {origin_url}")
        task = scheduler_host.check_output(
            f"swh scheduler task add load-{origin_type} url={origin_url}"
        )
        m = re.search(r"^Task (?P<id>\d+)$", task, flags=re.MULTILINE)
        assert m
        taskid = m.group("id")
        assert int(taskid) > 0

        for i in range(120):
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
                    assert False, (
                        "Loading execution failed\n"
                        f"status: {status}\n"
                        f"loader logs: " + loader_logs
                    )
                assert False, f"Loading execution failed, task status is {status}"
    return origin_urls


# Utility functions
def apiget(path: str, verb: str = "GET", baseurl: str = APIURL, **kwargs):
    """Query the API at path and return the json result or raise an
    AssertionError"""
    assert path[0] != "/", "you probably do not want that..."
    url = urljoin(baseurl, path)
    resp = requests.request(verb, url, **kwargs)
    assert resp.status_code == 200, f"failed to retrieve {url}: {resp.text}"
    if verb.lower() == "head":
        return resp
    else:
        return resp.json()


def pollapi(path: str, verb: str = "GET", baseurl: str = APIURL, **kwargs):
    """Poll the API at path until it returns an OK result"""
    url = urljoin(baseurl, path)
    for i in range(60):
        resp = requests.request(verb, url, **kwargs)
        if resp.ok:
            break
        time.sleep(1)
    else:
        assert False, f"Polling {url} failed"
    return resp


def getdirectory(
    dirid: str, currentpath: str = "", apiurl: str = APIURL
) -> Generator[Tuple[str, Mapping], None, None]:
    """Recursively retrieve directory description from the archive"""
    directory = apiget(f"directory/{dirid}", baseurl=apiurl)
    for direntry in directory:
        path = join(currentpath, direntry["name"])
        if direntry["type"] != "dir":
            yield (path, direntry)
        else:
            yield from getdirectory(direntry["target"], path, apiurl)
