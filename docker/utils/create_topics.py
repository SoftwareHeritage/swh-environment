import time

from confluent_kafka.admin import AdminClient, NewTopic

TOPICS = [
    "swh.journal.objects.content",
    "swh.journal.objects.directory",
    "swh.journal.objects.extid",
    "swh.journal.objects.origin",
    "swh.journal.objects.origin_visit",
    "swh.journal.objects.origin_visit_status",
    "swh.journal.objects.raw_extrinsic_metadata",
    "swh.journal.objects.release",
    "swh.journal.objects.revision",
    "swh.journal.objects.skipped_content",
    "swh.journal.objects.snapshot",
    "swh.journal.objects_privileged.release",
    "swh.journal.objects_privileged.revision",
    "swh.journal.indexed.origin_intrinsic_metadata",
]


def create_topics(topics):
    c = AdminClient({"bootstrap.servers": "kafka:9092"})
    m = c.list_topics()
    topics_to_create = set(topics) - set(m.topics.keys())
    if topics_to_create:
        print("Topics to create", sorted(topics_to_create))
        new_topics = []
        for topic in topics_to_create:
            config = {}
            if topic.startswith("swh.journal.objects"):
                config.update(
                    {
                        "cleanup.policy": "compact",
                        # delete old events after 1 second
                        "max.compaction.lag.ms": 1_000,
                        # delete tombstones after 1 hour
                        "delete.retention.ms": 3_600_000,
                    }
                )
            new_topics.append(NewTopic(topic, config=config))
        ft = c.create_topics(new_topics)
        while any(f.running() for t, f in ft.items()):
            time.sleep(0.1)
    else:
        print("Nothing to do")


if __name__ == "__main__":
    create_topics(TOPICS)
