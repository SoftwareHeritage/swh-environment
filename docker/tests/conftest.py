# Copyright (C) 2019-2024  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import atexit
from functools import partial
import os
import re
import shutil
from subprocess import CalledProcessError, check_output
import time
from typing import Iterable, List, Tuple, Union
from urllib.parse import urlparse
from uuid import uuid4 as uuid

import pytest
import requests
import testinfra
import yaml

from .utils import api_get as api_get_func
from .utils import api_get_directory as api_get_directory_func
from .utils import api_poll as api_poll_func

DOCKER_BRIDGE_NETWORK_GATEWAY_IP = "172.17.0.1"

# wait-for-it timeout
WFI_TIMEOUT = 120


def pytest_collection_modifyitems(config, items):
    """Tests for swh-environment require docker compose (v2 or v1) so skip them
    if it is not installed on host."""
    skipper = None
    if shutil.which("docker") is None:
        skipper = pytest.mark.skip(reason="skipping test as docker command is missing")
    else:
        docker_compose_available = False
        try:
            # check if docker compose v2 if available
            check_output(["docker", "compose", "version"])
            docker_compose_available = True
        except CalledProcessError:
            # check if docker compose v1 if available
            docker_compose_available = shutil.which("docker-compose") is not None
        finally:
            if not docker_compose_available:
                skipper = pytest.mark.skip(
                    reason="skipping test as docker compose is missing"
                )
    if skipper is not None:
        for item in items:
            item.add_marker(skipper)


@pytest.fixture(scope="module")
def docker_host():
    return testinfra.get_host("local://")


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    # this fixture is meant to be overloaded in test modules to include the
    # required compose files for the test (see test_deposit.py for example)
    return ["docker-compose.yml"]


@pytest.fixture(scope="module")
def compose_services() -> List[str]:
    # this fixture is meant to be overloaded in test modules to explicitly
    # specify which services to spawn in the docker compose session.
    # If empty (the default), spawn all the services defined in the compose files.
    return []


@pytest.fixture(scope="module")
def project_name() -> str:
    return f"swh_test_{uuid()}"


def _patch_compose_files(compose_files, compose_files_tmpdir):
    """Patch original compose files to modify the way service ports are bound
    by picking free ports on the docker host."""
    tmp_compose_files = []
    for compose_file in compose_files:
        tmp_compose_file = compose_files_tmpdir.join(compose_file)
        if os.path.exists(tmp_compose_file):
            # compose file already patched, nothing to do
            tmp_compose_files.append(tmp_compose_file)
            continue
        with open(compose_file, "r") as compose_file_stream:
            compose_file_data = yaml.load(compose_file_stream, Loader=yaml.Loader)
            for service in compose_file_data.get("services", {}).values():
                ports_conf = service.get("ports")
                if not ports_conf:
                    continue
                new_ports = []
                for ports_bindings in ports_conf:
                    ports = str(ports_bindings).split(":")
                    if len(ports) > 1:
                        new_ports.append(f"0:{ports[1]}")
                    else:
                        new_ports.append(ports_bindings)
                service["ports"] = new_ports
            with open(tmp_compose_file, "w") as tmp_compose_file_stream:
                yaml.dump(compose_file_data, tmp_compose_file_stream)
            tmp_compose_files.append(tmp_compose_file)
    return tmp_compose_files


@pytest.fixture(scope="session")
def compose_files_tmpdir(tmpdir_factory):
    # create a temporary directory to store patched compose files
    tmpdir = tmpdir_factory.mktemp("compose_files", numbered=False)
    compose_files_dir = os.path.join(os.path.dirname(__file__), "..")
    # create symlinks in that directory to the paths referenced in compose files
    for _, dirs, _ in os.walk(compose_files_dir):
        for dir_ in (d for d in dirs if not d.startswith(".") and d != "conf"):
            os.symlink(
                os.path.join(compose_files_dir, dir_),
                os.path.join(tmpdir, dir_),
                target_is_directory=True,
            )
        break
    shutil.copytree(
        os.path.join(compose_files_dir, "conf"), os.path.join(tmpdir, "conf")
    )
    return tmpdir


@pytest.fixture(scope="module")
def compose_cmd(docker_host, project_name, compose_files, compose_files_tmpdir):
    print(f"patching compose files: {', '.join(compose_files)}")
    tmp_compose_files = _patch_compose_files(compose_files, compose_files_tmpdir)
    print(f"compose project is {project_name}")
    compose_file_cmd = "".join(f" -f {fname} " for fname in tmp_compose_files)
    try:
        docker_host.check_output("docker compose version")
        return f"docker compose -p {project_name} {compose_file_cmd} "
    except AssertionError:
        print("Fall back to old docker-compose command")
        return f"docker-compose -p {project_name} {compose_file_cmd} "


def stop_compose_session(docker_host, project_name, compose_cmd):
    print(f"\nStopping the compose session {project_name}...", end=" ", flush=True)
    # first kill all the containers (brutal but much faster than a proper shutdown)
    containers = docker_host.check_output(f"{compose_cmd} ps -q").replace("\n", " ")
    if containers:
        try:
            docker_host.check_output(f"docker kill {containers}")
        except AssertionError:
            # may happen if a container is killed as a result of another one
            # being shut down...
            pass
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


# scope='module' so we use the same container for all the tests in a test file
@pytest.fixture(scope="module")
def docker_compose(
    request, docker_host, project_name, compose_cmd, compose_services, tmp_path_factory
):
    # register an exit handler to ensure started containers will be stopped if any
    # keyboard interruption or unhandled exception occurs
    stop_compose_func = atexit.register(
        stop_compose_session, docker_host, project_name, compose_cmd
    )
    failed_tests_count = request.node.session.testsfailed
    print(f"Starting the compose session {project_name}...", end=" ", flush=True)
    try:
        # pull required docker images
        docker_host.check_output(f"{compose_cmd} pull --ignore-pull-failures")

        # start the whole cluster
        docker_host.check_output(
            f"{compose_cmd} up --wait -d {' '.join(compose_services)}"
        )
        print("OK")

        # small hack: add a helper func to docker_host; so it's not necessary to
        # use all 3 docker_compose, docker_host and compose_cmd fixtures everywhere
        docker_host.check_compose_output = lambda command: docker_host.check_output(
            f"{compose_cmd} {command}"
        )
        services = docker_host.check_compose_output("ps --services").splitlines()
        print(f"Started {len(services)} services")
        yield docker_host
    finally:
        if request.node.session.testsfailed != failed_tests_count:
            logs_filename = request.node.name.replace(".py", ".logs")
            logs_dir = os.path.join(tmp_path_factory.getbasetemp(), "docker")
            os.makedirs(logs_dir, exist_ok=True)
            logs_filepath = os.path.join(logs_dir, logs_filename)
            print(
                f"Tests failed in {request.node.name}, "
                f"dumping logs to {logs_filepath}"
            )
            services = docker_host.check_output(f"{compose_cmd} ps --services --all")
            for service in services.splitlines():
                logs = docker_host.check_output(f"{compose_cmd} logs -t {service}")
                with open(logs_filepath, "a") as logs_file:
                    logs_file.write(logs)

        atexit.unregister(stop_compose_func)
        stop_compose_session(docker_host, project_name, compose_cmd)


@pytest.fixture(scope="module")
def nginx_url(docker_compose, compose_cmd) -> str:
    port_output = docker_compose.check_output(f"{compose_cmd} port nginx 5080")
    bound_port = port_output.split(":")[1]
    # as tests could be executed inside a container, we use the docker bridge
    # network gateway ip instead of localhost domain name
    return f"http://{DOCKER_BRIDGE_NETWORK_GATEWAY_IP}:{bound_port}"


@pytest.fixture(scope="module")
def api_url(nginx_url) -> str:
    return f"{nginx_url}/api/1/"


@pytest.fixture(scope="module")
def kafka_api_url(nginx_url) -> str:
    return f"{nginx_url}/kafka/v3/clusters"


def compose_host_for_service(docker_compose, service):
    docker_id = docker_compose.check_compose_output(
        f"ps {service} --format '{{{{.ID}}}}'"
    )
    if docker_id:
        return testinfra.get_host("docker://" + docker_id)


@pytest.fixture(scope="module")
def scheduler_host(request, docker_compose):
    # run a container in which test commands are executed
    scheduler_host = compose_host_for_service(docker_compose, "swh-scheduler")
    assert scheduler_host
    scheduler_host.check_output(f"wait-for-it swh-storage:5002 -t {WFI_TIMEOUT}")

    # return a testinfra connection to the container
    yield scheduler_host


@pytest.fixture(scope="module")
def api_get(api_url):
    return partial(api_get_func, api_url)


@pytest.fixture(scope="module")
def nginx_get(nginx_url):
    return partial(api_get_func, nginx_url)


@pytest.fixture(scope="module")
def api_poll(api_url):
    return partial(api_poll_func, api_url)


@pytest.fixture(scope="module")
def api_get_directory(api_url):
    return partial(api_get_directory_func, api_url)


@pytest.fixture(scope="module")
def webapp_host(docker_compose):
    webapp_host = compose_host_for_service(docker_compose, "swh-web")
    assert webapp_host
    webapp_host.check_output(f"wait-for-it swh-storage:5002 -t {WFI_TIMEOUT}")

    # return a testinfra connection to the container
    yield webapp_host


@pytest.fixture(scope="module")
def origin_urls() -> List[Tuple[str, Union[str, Iterable[str]]]]:
    # This fixture is meant to be overloaded in test modules to initialize the
    # main storage with the content from the loading of the origins listed
    # here. By default we only load one git origin (to try to keep execution
    # time under control), but some tests may require more than that.
    return [("git", "https://gitlab.softwareheritage.org/swh/devel/swh-core.git")]


def filter_origins(origin_urls: Iterable[str]) -> str:
    """From a list of urls, return the first one that is reachable"""
    if isinstance(origin_urls, str):
        origin_urls = [origin_urls]

    for origin_url in origin_urls:
        parsed_url = urlparse(origin_url)
        if parsed_url.scheme in ("http", "https"):
            try:
                requests.head(origin_url, timeout=5).raise_for_status()
                return origin_url
            except Exception as exc:
                print(f"Failed to connect to {origin_url}: {exc}")
                continue
        else:
            # not a http url, assume it's ok
            return origin_url
    raise AssertionError("Unable to contact any origin of {origin_urls}")


@pytest.fixture(scope="module")
def origins(docker_compose, scheduler_host, origin_urls: List[Tuple[str, str]]):
    """A fixture that ingest origins from origin_urls in the storage

    For each origin url listed in origin_urls, scheduler a loading task and
    wait for all the loading tasks to finish. Check these are in the 'eventful'
    state.
    """

    origin_urls = [(otype, filter_origins(urls)) for (otype, urls) in origin_urls]
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
