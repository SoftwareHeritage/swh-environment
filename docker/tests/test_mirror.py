# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

from functools import partial
from time import sleep
from typing import List
from urllib.parse import quote_plus

import pytest
import requests

from .conftest import APIURL
from .conftest import apiget as apiget_
from .conftest import getdirectory as getdirectory_
from .test_vault import test_vault_directory, test_vault_git_bare  # noqa

MIRROR_API = "http://127.0.0.1:5081/api/1/"
KAFKA_REST_API = "http://127.0.0.1:5080/kafka/v3/clusters"


@pytest.fixture(scope="module")
def api_url(mirror) -> str:
    return MIRROR_API


@pytest.fixture(scope="module")
def origin_urls():
    return [
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-core.git"),
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-model.git"),
        ("hg", "https://hg.sr.ht/~douardda/pygpibtoolkit"),
    ]


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    return ["docker-compose.yml", "docker-compose.mirror.yml"]


@pytest.fixture(scope="module")
def mirror(docker_host, compose_cmd, origins):
    apiget = partial(apiget_, baseurl=APIURL)
    mirror_apiget = partial(apiget_, baseurl=MIRROR_API)
    # this fixture ensures the origins have been loaded in the prinmary
    # storage, the mirror is up, and the replayers are done
    ps = f"{compose_cmd} ps --quiet "
    while docker_host.check_output(f"{ps} --status created"):
        sleep(0.2)
    print("Checking there is no dead service")
    assert not docker_host.check_output(f"{ps} --status dead")
    assert not docker_host.check_output(f"{ps} --status exited")

    print("Checking core services are reported as ok")
    print("Storage...", end=" ", flush=True)
    assert docker_host.check_output(f"{ps} --status running swh-storage")
    print("OK")
    print("Mirror Storage...", end=" ", flush=True)
    assert docker_host.check_output(f"{ps} --status running swh-mirror-storage")
    print("OK")
    print("Kafka REST proxy...", end=" ", flush=True)
    assert docker_host.check_output(f"{ps} --status running kafka-rest")
    print("OK")

    expected_urls = set(url for _, url in origins)

    print("Checking origins exists in the main storage")
    # ensure all the origins have been loaded, should not be needed but...
    m_origins = set(x["url"] for x in apiget("origins/"))
    assert m_origins == expected_urls, "not all origins have been loaded"

    cluster = requests.get(KAFKA_REST_API).json()["data"][0]["cluster_id"]

    def kget(path):
        url = f"{KAFKA_REST_API}/{cluster}/{path}"
        resp = requests.get(url)
        if resp.status_code == 200:
            return resp.json()
        resp.raise_for_status()

    # wait until the replayer is done
    print("Waiting for the replayer to be done")
    for _ in range(30):
        lag_sum = kget("consumer-groups/swh.storage.mirror.replayer/lag-summary")
        if lag_sum["total_lag"] == 0:
            break
        sleep(1)
    else:
        raise AssertionError(
            "Could not detect a condition where the replayer did its job"
        )

    print("Checking we have origins in the mirror")
    # at this point, origins should be in the mirror storage...
    for _ in range(30):
        m_origins = set(x["url"] for x in mirror_apiget("origins/"))
        if m_origins == expected_urls:
            break
        sleep(1)
    else:
        assert m_origins == expected_urls, "not all origins have been replicated"

    print("Waiting for the content replayer to be done")
    # wait until the content replayer is done
    for _ in range(30):
        lag_sum = kget("consumer-groups/swh.objstorage.mirror.replayer/lag-summary")
        if lag_sum["total_lag"] == 0:
            break
        sleep(1)
    else:
        raise AssertionError(
            "Could not detect a condition where the content replayer did its job"
        )


def test_mirror_replication(origins, mirror, api_url):
    apiget = partial(apiget_, baseurl=APIURL)
    getdirectory = partial(getdirectory_, apiurl=APIURL)
    mirror_apiget = partial(apiget_, baseurl=api_url)

    def filter_obj(objd):
        if isinstance(objd, dict):
            return {
                k: filter_obj(v)
                for (k, v) in objd.items()
                if not (isinstance(v, str) and v.startswith("http://127.0.0.1:"))
            }
        elif isinstance(objd, list):
            return [filter_obj(e) for e in objd]
        else:
            return objd

    print("Check every git object has been replicated in the mirror")
    # check all the objects are present in the mirror...
    for _, origin_url in origins:
        print(f"... for {origin_url}")
        visit1 = apiget(f"origin/{quote_plus(origin_url)}/visit/latest")
        visit2 = mirror_apiget(f"origin/{quote_plus(origin_url)}/visit/latest")
        assert filter_obj(visit1) == filter_obj(visit2)

        snapshot1 = apiget(f'snapshot/{visit1["snapshot"]}')
        snapshot2 = mirror_apiget(f'snapshot/{visit2["snapshot"]}')
        assert filter_obj(snapshot1) == filter_obj(snapshot2)

        assert snapshot1["branches"]["HEAD"]["target_type"] == "alias"
        tgt_name = snapshot1["branches"]["HEAD"]["target"]
        target = snapshot1["branches"][tgt_name]
        assert target["target_type"] == "revision"
        rev_id = target["target"]
        revision1 = apiget(f"revision/{rev_id}")
        revision2 = mirror_apiget(f"revision/{rev_id}")
        assert filter_obj(revision1) == filter_obj(revision2)

        dir_id = revision1["directory"]

        directory = getdirectory(dir_id)
        mirror_directory = getdirectory(dir_id, apiurl=MIRROR_API)

        for (p1, e1), (p2, e2) in zip(directory, mirror_directory):
            assert p1 == p2
            assert filter_obj(e1) == filter_obj(e2)
            if e1["type"] == "file":
                # here we check the content object is known by both the objstorages
                target = e1["target"]
                apiget(f"content/sha1_git:{target}/raw/", verb="HEAD")
                mirror_apiget(f"content/sha1_git:{target}/raw/", verb="HEAD")
