# Copyright (C) 2019-2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import itertools
from os.path import join
import time
from typing import Generator, Mapping, Tuple
from urllib.parse import urljoin

import requests


def grouper(iterable, n):
    # copied from swh.core.utils
    args = [iter(iterable)] * n
    stop_value = object()
    for _data in itertools.zip_longest(*args, fillvalue=stop_value):
        yield (d for d in _data if d is not stop_value)


# Utility functions
def api_get(baseurl: str, path: str, verb: str = "GET", **kwargs):
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


def api_poll(baseurl: str, path: str, verb: str = "GET", **kwargs):
    """Poll the API at path until it returns an OK result"""
    url = urljoin(baseurl, path)
    for _ in range(60):
        resp = requests.request(verb, url, **kwargs)
        if resp.ok:
            break
        time.sleep(1)
    else:
        raise AssertionError(f"Polling {url} failed")
    return resp


def api_get_directory(
    apiurl: str, dirid: str, currentpath: str = ""
) -> Generator[Tuple[str, Mapping], None, None]:
    """Recursively retrieve directory description from the archive"""
    directory = api_get(apiurl, f"directory/{dirid}/")
    for direntry in directory:
        path = join(currentpath, direntry["name"])
        if direntry["type"] != "dir":
            yield (path, direntry)
        else:
            yield from api_get_directory(apiurl, direntry["target"], path)
