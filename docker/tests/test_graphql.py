# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import pytest
import requests


@pytest.fixture(scope="module")
def graphql_url(nginx_url) -> str:
    return f"{nginx_url}/graphql/"


@pytest.fixture(scope="module")
def origin_urls():
    return [
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-core.git"),
        (
            "hg",
            [
                "https://hg.sdfa3.org/pygpibtoolkit",
                "https://hg.sr.ht/~douardda/pygpibtoolkit",
            ],
        ),
        ("git", "https://gitlab.softwareheritage.org/swh/devel/swh-model.git"),
    ]


def test_graphql(origins, api_get, graphql_url):
    # a very minimal test for graphql
    print("Checking origins exists in the main storage")
    # ensure all the origins have been loaded, should not be needed but...
    m_origins = set(x["url"] for x in api_get("origins/"))
    expected_urls = set(url for _, url in origins)
    assert m_origins == expected_urls, "not all origins have been loaded"

    # get 2 of the 3 origins
    query = {"query": "query {origins(first: 2) {nodes {url}}}"}
    resp = requests.post(graphql_url, json=query)
    assert resp.status_code == 200
    result = resp.json()
    origins = set(n["url"] for n in result["data"]["origins"]["nodes"])
    assert len(origins) == 2
    assert origins.issubset(expected_urls)

    # get all the 3 origins
    query = {"query": "query {origins(first: 10) {nodes {url}}}"}
    resp = requests.post(graphql_url, json=query)
    assert resp.status_code == 200
    result = resp.json()
    origins = set(n["url"] for n in result["data"]["origins"]["nodes"])
    assert origins == expected_urls
