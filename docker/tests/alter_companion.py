# Copyright (C) 2023  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

from http import HTTPStatus
import http.server
import itertools
import json
from socket import socket
import sys
from typing import Dict, Iterator, List, Tuple, Union

import click
from confluent_kafka import Message


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


########################################################################
# Kafka
#


def handle_message(
    content_journal_key_to_swhid: Dict[bytes, str],
    message: Message,
) -> Iterator[Tuple[str, Message]]:
    import hashlib

    import msgpack

    key = msgpack.unpackb(message.key())
    match message.topic():
        case "swh.journal.objects.origin":
            sha1 = hashlib.sha1(key["url"].encode("us-ascii")).hexdigest()
            yield f"swh:1:ori:{sha1}", message
        case (
            "swh.journal.objects.origin_visit"
            | "swh.journal.objects.origin_visit_status"
        ):
            # XXX: This is interesting to check absence, but for presence it
            # might lead to bad results… not sure what is the right move.
            sha1 = hashlib.sha1(key["origin"].encode("us-ascii")).hexdigest()
            yield f"swh:1:ori:{sha1}", message
        case "swh.journal.objects.snapshot":
            yield f"swh:1:snp:{key.hex()}", message
        case "swh.journal.objects.release" | "swh.journal.objects_privileged.release":
            yield f"swh:1:rel:{key.hex()}", message
        case "swh.journal.objects.revision" | "swh.journal.objects_privileged.revision":
            yield f"swh:1:rev:{key.hex()}", message
        case "swh.journal.objects.directory":
            yield f"swh:1:dir:{key.hex()}", message
        case "swh.journal.objects.content":
            # We need to do the map dance because the key for content is `sha1`
            # and not `sha1_git`.
            if key in content_journal_key_to_swhid:
                swhid = content_journal_key_to_swhid[key]
            else:
                value = message.value()
                if value:
                    d = msgpack.unpackb(message.value())
                    swhid = f"swh:1:cnt:{d['sha1_git'].hex()}"
                    content_journal_key_to_swhid[key] = swhid
                else:
                    print(
                        "Unknown SWHID for content tombstone. Key: {key.hex()}",
                        file=sys.stderr,
                    )
                    return
            yield swhid, message
        case topic:
            print(f"unhandled topic {topic} -> {key}", file=sys.stderr)


def lookup_kafka_messages() -> Iterator[Tuple[str, Message]]:
    import uuid

    from confluent_kafka import Consumer, KafkaException

    consumer = Consumer(
        {
            "bootstrap.servers": "kafka:9092",
            # Use a different group ID each time so we are
            # sure we will receive all objects
            "group.id": f"swh.alter.companion.{uuid.uuid4()}",
            "auto.offset.reset": "smallest",
            "enable.auto.commit": "false",
        }
    )
    try:
        consumer.subscribe(
            [
                "swh.journal.objects.origin",
                "swh.journal.objects.origin_visit",
                "swh.journal.objects.origin_visit_status",
                "swh.journal.objects.snapshot",
                "swh.journal.objects.release",
                "swh.journal.objects_privileged.release",
                "swh.journal.objects.revision",
                "swh.journal.objects_privileged.revision",
                "swh.journal.objects.directory",
                "swh.journal.objects.content",
                "swh.journal.objects.skipped_content",
                # XXX: We are not considering
                # swh.journal.objects.extid
                # swh.journal.objects.raw_extrinsic_metadata
            ]
        )

        # Because key for Content objects are using `sha1` and not `sha1_git`,
        # we need to keep a map from one to the other to properly handle
        # tombstones.
        content_journal_key_to_swhid: Dict[bytes, str] = {}

        while True:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                break
            error = msg.error()
            if error is not None:
                raise KafkaException(error)
            yield from handle_message(content_journal_key_to_swhid, msg)
    finally:
        consumer.close()


def get_timestamp(message: Message) -> int:
    from confluent_kafka import TIMESTAMP_CREATE_TIME

    timestamp_type, value = message.timestamp()
    if timestamp_type == TIMESTAMP_CREATE_TIME:
        return value
    else:
        return 0


SWHID_ORDER = {"cnt": 0, "dir": 1, "rev": 2, "rel": 3, "snp": 4, "ori": 5}


def swhid_key(swhid: str) -> str:
    return f"{SWHID_ORDER[swhid[6:9]]}{swhid[11:]}"


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
def query_kafka(ctx: click.Context, presence: bool, swhids: List[str]) -> None:
    """Ensure that the given SWHIDs are absent in Kafka (swh-journal)"""

    searched_swhids = set(swhids)
    journal_swhids: Dict[str, Tuple[int, bool]] = {}
    for key, message in lookup_kafka_messages():
        timestamp = get_timestamp(message)
        if key in journal_swhids and journal_swhids[key][0] > timestamp:
            continue
        tombstone = message.value() is None
        journal_swhids[key] = (timestamp, tombstone)
    found_swhids = {swhid for swhid, t in journal_swhids.items() if not t[1]}
    if presence:
        if found_swhids.issuperset(searched_swhids):
            ctx.exit(0)
        else:
            print("Not found:\n")
            for swhid in sorted(searched_swhids - found_swhids, key=swhid_key):
                click.echo(swhid)
            ctx.exit(1)
    else:
        if found_swhids.isdisjoint(searched_swhids):
            ctx.exit(0)
        else:
            print("Found nonetheless:\n")
            for swhid in sorted(found_swhids & searched_swhids, key=swhid_key):
                click.echo(swhid)
            ctx.exit(1)


if __name__ == "__main__":
    cli()
