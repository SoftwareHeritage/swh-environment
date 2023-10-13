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
    new_topics = set(topics) - set(m.topics.keys())
    if new_topics:
        print("Topics to create", sorted(new_topics))
        ft = c.create_topics([NewTopic(t) for t in new_topics])
        while any(f.running() for t, f in ft.items()):
            time.sleep(0.1)
    else:
        print("Nothing to do")


if __name__ == "__main__":
    create_topics(TOPICS)
