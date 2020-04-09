# Copyright (C) 2019-2020  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import re
import subprocess
import time

import requests

from os.path import join
from typing import Generator, Mapping, Tuple
from urllib.parse import urljoin

import pytest
import testinfra


APIURL = 'http://127.0.0.1:5080/api/1/'

SAMPLE_METADATA = '''\
<?xml version="1.0" encoding="utf-8"?>
<entry xmlns="http://www.w3.org/2005/Atom"
       xmlns:codemeta="https://doi.org/10.5063/SCHEMA/CODEMETA-2.0">
  <title>Test Software</title>
  <client>swh</client>
  <external_identifier>test-software</external_identifier>
  <codemeta:author>
    <codemeta:name>No One</codemeta:name>
  </codemeta:author>
</entry>
'''


# scope='session' so we use the same container for all the tests;
@pytest.fixture(scope='session')
def docker_compose(request):
    # start the whole cluster
    subprocess.check_output(['docker-compose', 'up', '-d'])
    yield
    # and strop it
    subprocess.check_call(['docker-compose', 'down'])


@pytest.fixture(scope='session')
def wfi_timeout():
    """
    wait-for-it timeout in seconds
    """
    return 60


@pytest.fixture(scope='session')
def scheduler_host(request, docker_compose, wfi_timeout):
    # run a container in which test commands are executed
    docker_id = subprocess.check_output(
        ['docker-compose', 'run', '-d',
         'swh-scheduler', 'shell', 'sleep', '1h']).decode().strip()
    scheduler_host = testinfra.get_host("docker://" + docker_id)
    scheduler_host.check_output(
        f'wait-for-it swh-scheduler:5008 -t {wfi_timeout}')
    scheduler_host.check_output(
        f'wait-for-it swh-storage:5002 -t {wfi_timeout}')

    # return a testinfra connection to the container
    yield scheduler_host

    # at the end of the test suite, destroy the container
    subprocess.check_call(['docker', 'rm', '-f', docker_id])


# scope='session' so we use the same container for all the tests;
@pytest.fixture(scope='session')
def deposit_host(request, docker_compose, wfi_timeout):
    # run a container in which test commands are executed
    docker_id = subprocess.check_output(
        ['docker-compose', 'run', '-d',
         'swh-deposit', 'shell', 'sleep', '1h']).decode().strip()
    deposit_host = testinfra.get_host("docker://" + docker_id)
    deposit_host.check_output(
        'echo \'print("Hello World!")\n\' > /tmp/hello.py')
    deposit_host.check_output(
        'tar -C /tmp -czf /tmp/archive.tgz /tmp/hello.py')
    deposit_host.check_output(
        f'echo \'{SAMPLE_METADATA}\' > /tmp/metadata.xml')
    deposit_host.check_output(
        f'wait-for-it swh-deposit:5006 -t {wfi_timeout}')
    # return a testinfra connection to the container
    yield deposit_host

    # at the end of the test suite, destroy the container
    subprocess.check_call(['docker', 'rm', '-f', docker_id])


@pytest.fixture(scope='session')
def git_url():
    return 'https://forge.softwareheritage.org/source/swh-core'


@pytest.fixture(scope='session')
def git_origin(scheduler_host, git_url):
    task = scheduler_host.check_output(
        f'swh scheduler task add load-git url={git_url}'
    )
    taskid = re.search(r'^Task (?P<id>\d+)$', task,
                       flags=re.MULTILINE).group('id')
    assert int(taskid) > 0

    for i in range(60):
        status = scheduler_host.check_output(
            f'swh scheduler task list --list-runs --task-id {taskid}')
        if 'Executions:' in status:
            if '[eventful]' in status:
                break
            if '[started]' in status or '[scheduled]' in status:
                time.sleep(1)
                continue
            if '[failed]' in status:
                loader_logs = subprocess.check_output(
                    ['docker-compose', 'logs', 'swh-loader'])
                assert False, ('Loading execution failed\n'
                               f'status: {status}\n'
                               f'loader logs: '
                               + loader_logs.decode(errors='replace'))
            assert False, f'Loading execution failed, task status is {status}'
    return git_url


# Utility functions

def apiget(path: str, verb: str = 'GET', **kwargs):
    """Query the API at path and return the json result or raise an
    AssertionError"""

    url = urljoin(APIURL, path)
    resp = requests.request(verb, url, **kwargs)
    assert resp.status_code == 200, f'failed to retrieve {url}: {resp.text}'
    return resp.json()


def pollapi(path: str, verb: str = 'GET', **kwargs):
    """Poll the API at path until it returns an OK result"""
    url = urljoin(APIURL, path)
    for i in range(60):
        resp = requests.request(verb, url, **kwargs)
        if resp.ok:
            break
        time.sleep(1)
    else:
        assert False, f"Polling {url} failed"
    return resp


def getdirectory(dirid: str, currentpath: str = '') \
        -> Generator[Tuple[str, Mapping], None, None]:
    """Recursively retrieve directory description from the archive"""
    directory = apiget(f'directory/{dirid}')
    for direntry in directory:
        path = join(currentpath, direntry['name'])
        if direntry['type'] != 'dir':
            yield (path, direntry)
        else:
            yield from getdirectory(direntry['target'], path)
