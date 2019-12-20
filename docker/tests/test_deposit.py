# Copyright (C) 2019-2020  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import json
import subprocess
import time

import pytest
import testinfra


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
def deposit_host(request):
    # start the whole cluster
    subprocess.check_output(['docker-compose', 'up', '-d'])
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
    deposit_host.check_output('wait-for-it swh-deposit:5006 -t 30')
    # return a testinfra connection to the container
    yield deposit_host

    # at the end of the test suite, destroy the container
    subprocess.check_call(['docker', 'rm', '-f', docker_id])
    # and the wole cluster
    subprocess.check_call(['docker-compose', 'down'])


def test_admin_collection(deposit_host):
    # 'deposit_host' binds to the container
    assert deposit_host.check_output(
        'swh deposit admin collection list') == 'test'


def test_admin_user(deposit_host):
    assert deposit_host.check_output('swh deposit admin user list') == 'test'


def test_create_deposit_simple(deposit_host):
    deposit = deposit_host.check_output(
        'swh deposit upload --format json --username test --password test '
        '--url http://nginx:5080/deposit/1 '
        '--archive /tmp/archive.tgz '
        '--name test_deposit --author somebody')
    deposit = json.loads(deposit)

    assert set(deposit.keys()) == {'deposit_id', 'deposit_status',
                                   'deposit_status_detail', 'deposit_date'}
    assert deposit['deposit_status'] == 'deposited'
    deposit_id = deposit['deposit_id']

    for i in range(60):
        status = json.loads(deposit_host.check_output(
            'swh deposit status --format json --username test --password test '
            '--url http://nginx:5080/deposit/1 --deposit-id %s' % deposit_id))
        if status['deposit_status'] == 'done':
            break
        time.sleep(1)
    else:
        assert False, "Deposit loading failed"


def test_create_deposit_with_metadata(deposit_host):
    deposit = deposit_host.check_output(
        'swh deposit upload --format json --username test --password test '
        '--url http://nginx:5080/deposit/1 '
        '--archive /tmp/archive.tgz '
        '--metadata /tmp/metadata.xml')
    deposit = json.loads(deposit)

    assert set(deposit.keys()) == {'deposit_id', 'deposit_status',
                                   'deposit_status_detail', 'deposit_date'}
    assert deposit['deposit_status'] == 'deposited'
    deposit_id = deposit['deposit_id']

    for i in range(60):
        status = json.loads(deposit_host.check_output(
            'swh deposit status --format json --username test --password test '
            '--url http://nginx:5080/deposit/1 --deposit-id %s' % deposit_id))
        if status['deposit_status'] == 'done':
            break
        time.sleep(1)
    else:
        assert False, "Deposit loading failed"


def test_create_deposit_multipart(deposit_host):
    deposit = deposit_host.check_output(
        'swh deposit upload --format json --username test --password test '
        '--url http://nginx:5080/deposit/1 '
        '--archive /tmp/archive.tgz '
        '--partial')
    deposit = json.loads(deposit)

    assert set(deposit.keys()) == {'deposit_id', 'deposit_status',
                                   'deposit_status_detail', 'deposit_date'}
    assert deposit['deposit_status'] == 'partial'
    deposit_id = deposit['deposit_id']

    deposit = deposit_host.check_output(
        'swh deposit upload --format json --username test --password test '
        '--url http://nginx:5080/deposit/1 '
        '--metadata /tmp/metadata.xml '
        '--deposit-id %s'
        % deposit_id)
    deposit = json.loads(deposit)
    assert deposit['deposit_status'] == 'deposited'
    assert deposit['deposit_id'] == deposit_id

    for i in range(60):
        status = json.loads(deposit_host.check_output(
            'swh deposit status --format json --username test --password test '
            '--url http://nginx:5080/deposit/1 --deposit-id %s' % deposit_id))
        if status['deposit_status'] == 'done':
            break
        time.sleep(1)
    else:
        assert False, "Deposit loading failed; current status is %s" % status
