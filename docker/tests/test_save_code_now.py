# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

from time import sleep

import pytest

# small git repository that takes a couple of seconds to load into the archive
ORIGIN_URL = "https://github.com/anlambert/highlightjs-line-numbers.js"
VISIT_TYPE = "git"


@pytest.fixture(
    scope="module",
    params=[
        ["docker-compose.yml"],
        [
            "docker-compose.yml",
            "docker-compose.webhooks.yml",
        ],
    ],
    ids=["pull request status", "push request status"],
)
def compose_files(request):
    return request.param


def test_save_code_now(webapp_host, api_get):
    api_path = f"origin/save/{VISIT_TYPE}/url/{ORIGIN_URL}/"
    # create save request
    api_get(api_path, verb="POST")
    # wait until it was successfully processed
    for _ in range(60):
        response = api_get(api_path)
        if response and response[0].get("save_task_status") == "succeeded":
            break
        sleep(1)
    else:
        raise AssertionError("Save Code Now request did not succeed")
