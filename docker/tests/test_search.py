# Copyright (C) 2023-2024  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import re
import time
from typing import List
from urllib.parse import quote_plus

import pytest


@pytest.fixture(scope="module")
def compose_files() -> List[str]:
    return ["docker-compose.yml", "docker-compose.search.yml"]


@pytest.fixture(scope="module")
def origin_urls():
    return [
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-core.git"),
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-model.git"),
        ("git", "https://github.com/rdicosmo/parmap.git"),
        ("pypi", "https://pypi.org/project/swh.core/"),
        ("pypi", "https://pypi.org/project/swh.model/"),
    ]


def test_origin_metadata_search(origins, docker_compose, nginx_get, api_get):
    # preliminary checks:
    for _, url in origins:
        # 1. Check the origin is in the archive (just in case)
        origin = api_get(f"origin/{quote_plus(url)}/get")
        assert origin["url"] == url
        # 2. Check the visit was indeed eventful
        visit = api_get(f"origin/{quote_plus(url)}/visit/latest")
        assert visit["status"] == "full"

    # 3. Check origins are in elasticserch
    es_resp = nginx_get("es/origin/_search")
    es_origins = [
        (hit["_source"]["visit_types"][0], hit["_source"]["url"])
        for hit in es_resp["hits"]["hits"]
    ]
    assert set(es_origins) == set(origins)

    metadata_patterns = {
        "https://pypi.org/project/swh.core/": "Software Heritage core utilities",
        "https://pypi.org/project/swh.model/": "Software Heritage data model",
        "https://github.com/rdicosmo/parmap.git": "roberto",
    }
    imd_urls = set(metadata_patterns)
    # 4. Wait for the swh-search journal client to have processed the intrinsic MD.
    # For this, we just scrape the logs of the
    # swh-search-journal-client-indexed service to look for log entries showing
    # the origins have been indexed. The service NEEDS to be executed with
    # DEBUG log level.
    matcher = re.compile(r"'id': '(?P<url>[^']+)'")
    for i in range(120):
        logs = docker_compose.check_compose_output(
            "logs swh-search-journal-client-indexed"
        )
        omd_proc_raws = [
            raw
            for raw in logs.splitlines()
            if "DEBUG:root:processing origin intrinsic_metadata" in raw
        ]
        urls = [
            m.group("url") for m in (matcher.search(row) for row in omd_proc_raws) if m
        ]
        if set(urls) == imd_urls:
            break
        time.sleep(1)
    else:
        print(logs)
        assert False, (
            "swh-search journal client did not process "
            "intrinsic metadata in a timely manner"
        )

    # 5. query swh-search directly with metadata_pattern=fulltext to check
    # these iMD have been indexed in ES.
    for url, pattern in metadata_patterns.items():
        for i in range(30):
            mds = nginx_get(
                "search/origin/search",
                verb="POST",
                json={"metadata_pattern": pattern},
            )
            if set(x["url"] for x in mds["d"]["results"]) == {url}:
                break
            time.sleep(0.5)
        else:
            assert False, (
                "swh-indexer-worker-journal(?) did not process origins with "
                "intrinsic metadata in a timely manner"
            )

    # 6. Check the metadata indexer storage (!) have them indexed. Unfortunately
    # we do not have an easy way to figure if the indexer-worker-journal-client
    # service did process said origins (not enough logging), so just poll the
    # service instead for now...
    for i in range(30):
        imd = nginx_get(
            "indexer-storage/origin_intrinsic_metadata",
            verb="POST",
            json={"urls": [url for _, url in origins]},
        )
        if set(x["d"]["id"] for x in imd) == imd_urls:
            break
        time.sleep(0.5)
    else:
        assert False, (
            "swh-indexer-worker-journal did not process origins with "
            "intrinsic metadata in a timely manner"
        )

    # Check the metadata can be queried via the public API
    # Note that this actually does 2 things: ask ES for origins matching the
    # fulltext, then query the indexer-storage for each selected origin to
    # retrieve the actually stored intrinsic metadata.
    mds = api_get("origin/metadata-search", params={"limit": 10, "fulltext": "roberto"})
    assert len(mds) == 1
    md = mds[0]
    assert md["metadata"]["mappings"] == ["codemeta"]
    assert md["metadata"]["metadata"]["name"] == "Parmap"
    assert md["metadata"]["metadata"]["programmingLanguage"] == "OCaml"
    assert md["metadata"]["tool"]["name"] == "swh-metadata-detector"
    imd = api_get(f"origin/{quote_plus(md['url'])}/intrinsic-metadata")
    assert md["metadata"]["metadata"] == imd

    mds = api_get(
        "origin/metadata-search",
        params={"limit": 10, "fulltext": "Software Heritage core utilities"},
    )
    assert len(mds) == 1
    md = mds[0]
    assert md["metadata"]["mappings"] == ["pkg-info"]
    assert md["metadata"]["metadata"]["name"] == "swh.core"
    assert (
        md["metadata"]["metadata"]["description"] == "Software Heritage core utilities"
    )
    assert md["metadata"]["tool"]["name"] == "swh-metadata-detector"
    imd = api_get(f"origin/{quote_plus(md['url'])}/intrinsic-metadata")
    assert md["metadata"]["metadata"] == imd

    # Check a more generic query return both pypi packages
    mds = api_get(
        "origin/metadata-search", params={"limit": 10, "fulltext": "Software Heritage"}
    )
    assert len(mds) == 2
