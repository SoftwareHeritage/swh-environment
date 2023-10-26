# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

from http import HTTPStatus
import http.server
import itertools
import json
from socket import socket
from typing import Tuple, Union

import click


@click.group()
def cli():
    pass


########################################################################
# Mock graph
#


class MockGraphHandler(http.server.BaseHTTPRequestHandler):
    def __init__(
        self,
        request: Union[socket, Tuple[bytes, socket]],
        client_address: Tuple[str, int],
        server: "MockGraphHTTPServer",
    ):
        super().__init__(request, client_address, server)

    def do_GET(self):
        if self.path.startswith("/visit/edges/"):
            self.send_error(HTTPStatus.NOT_FOUND)
        elif self.path.startswith("/neighbors/"):
            self.send_error(HTTPStatus.NOT_FOUND)
        elif self.path == "/stats":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            stats = {"num_nodes": 0}
            self.wfile.write(json.dumps(stats, ensure_ascii=True).encode("us-ascii"))
        else:
            self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR)


class MockGraphHTTPServer(http.server.HTTPServer):
    """Mock HTTP server passing as a swh-graph HTTP server.

    Its API is limited to the calls used by swh-alter. All requests
    return 404 so swh-alter code will fallback on querying storage
    instead.
    """

    def __init__(self, server_address: Tuple[str, int]):
        super().__init__(server_address, MockGraphHandler)


@cli.command()
def mock_graph():
    """Run a mock HTTP server passing as a swh-graph HTTP server on port 5009"""

    server = MockGraphHTTPServer(("0.0.0.0", 5009))
    server.serve_forever()


########################################################################
# PostgreSQL
#

OBJECT_TYPE_TO_POSTGRESQL_QUERY = {
    "ori": "SELECT COUNT(id) FROM origin WHERE digest(url, 'sha1') = %s",
    "snp": "SELECT COUNT(id) FROM snapshot WHERE id = %s",
    "rel": "SELECT COUNT(id) FROM release WHERE id = %s",
    "rev": "SELECT COUNT(id) FROM revision WHERE id = %s",
    "dir": "SELECT COUNT(id) FROM directory WHERE id = %s",
    "cnt": "SELECT COUNT(sha1) FROM content WHERE sha1_git = %s",
}


def validate_swhid(ctx, param, value):
    for swhid in value:
        if not swhid.startswith("swh:1:"):
            raise click.BadParameter(f"“{swhid}” is not a SWHID")
    return value


@cli.command()
@click.option(
    "--presence",
    is_flag=True,
    show_default=True,
    default=False,
    help="Ensure the given SWHIDs are present instead of absent",
)
@click.argument("swhids", nargs=-1, callback=validate_swhid)
@click.pass_context
def query_postgresql(ctx, presence, swhids):
    """Ensure that the given SWHIDs are absent in the PostgreSQL storage"""

    import psycopg2

    if presence:
        expected_count = 1
        message = "{} not found"
    else:
        expected_count = 0
        message = "{} found"

    conn = psycopg2.connect(
        "host=swh-storage-db dbname=swh-storage user=postgres password=testpassword"
    )
    cur = conn.cursor()
    error = False
    for object_type, grouped_swhids in itertools.groupby(
        sorted(swhids), lambda s: s[6:9]
    ):
        for swhid in grouped_swhids:
            cur.execute(
                OBJECT_TYPE_TO_POSTGRESQL_QUERY[object_type],
                (bytes.fromhex(swhid[10:]),),
            )
            if cur.fetchone()[0] != expected_count:
                click.echo(message.format(swhid))
                error = True
    ctx.exit(1 if error else 0)


########################################################################
# Cassandra
#

OBJECT_TYPE_TO_CASSANDRA_QUERY = {
    "ori": "SELECT COUNT(*) FROM origin WHERE sha1 = %s",
    "snp": "SELECT COUNT(*) FROM snapshot WHERE id = %s",
    "rel": "SELECT COUNT(*) FROM release WHERE id = %s",
    "rev": "SELECT COUNT(*) FROM revision WHERE id = %s",
    "dir": "SELECT COUNT(*) FROM directory WHERE id = %s",
    "cnt": "SELECT COUNT(*) FROM content_by_sha1_git WHERE sha1_git = %s",
}


@cli.command()
@click.option(
    "--presence",
    is_flag=True,
    show_default=True,
    default=False,
    help="Ensure the given SWHIDs are present instead of absent",
)
@click.argument("swhids", nargs=-1, callback=validate_swhid)
@click.pass_context
def query_cassandra(ctx, presence, swhids):
    """Ensure that the given SWHIDs are absent in the Cassandra storage"""

    from cassandra.cluster import Cluster

    if presence:
        expected_count = 1
        message = "{} not found"
    else:
        expected_count = 0
        message = "{} found"

    cluster = Cluster(["cassandra-seed"])
    session = cluster.connect("swh")
    error = False
    for object_type, grouped_swhids in itertools.groupby(
        sorted(swhids), lambda s: s[6:9]
    ):
        for swhid in grouped_swhids:
            result = session.execute(
                OBJECT_TYPE_TO_CASSANDRA_QUERY[object_type],
                (bytes.fromhex(swhid[10:]),),
            )
            if result.one().count != expected_count:
                click.echo(message.format(swhid))
                error = True
    ctx.exit(1 if error else 0)


if __name__ == "__main__":
    cli()
