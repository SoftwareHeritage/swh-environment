import os
from django.core.cache import cache

from swh.web.settings.common import * # noqa
MIDDLEWARE += ['swh.web.common.middlewares.HtmlPrettifyMiddleware']

AUTH_PASSWORD_VALIDATORS = []  # disable any pwd validation mechanism

DATABASES['default']['NAME'] = os.path.join(
    os.environ.get('HOME', '/tmp'), 'db.sqlite3')

cache.clear()
