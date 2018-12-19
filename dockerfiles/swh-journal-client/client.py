# Copyright (C) 2018  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU General Public License version 3, or any later version
# See top-level LICENSE file for more information

import logging

from swh.journal.client import JournalClient


class JournalClientLogger(JournalClient):
    """Client in charge of listing new received origins and origin_visits
       in the swh journal.

    """
    CONFIG_BASE_FILENAME = 'journal/logger'

    def __init__(self):
        # Only interested in content here so override the configuration
        super().__init__(extra_configuration={'object_types':
                                              ['origin', 'origin_visit']})

    def process_objects(self, messages):
        """Simply log messages received.

        """
        for msg in messages:
            logging.info('msg: %s' % msg)


if __name__ == '__main__':
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s %(process)d %(levelname)s %(message)s'
    )

    import click

    @click.command()
    def main():
        """Log the new received origin and origin_visits.

        """
        JournalClientLogger().process()

    main()
