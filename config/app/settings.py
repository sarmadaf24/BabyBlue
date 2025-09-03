import os
import sys
from datetime import timedelta

from celery.schedules import crontab

TESTING = "test" in sys.argv

# Build paths inside the project like this: os.path.join(BASE_DIR, ...)
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY = "1/R1VbUqcx+MxS1j#6=#2sDu1q7Unul06lNLoN5DROxMMxri63"

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = False

ALLOWED_HOSTS = ['blue.nawpa.ir', '127.0.0.1', 'localhost']

# Application definition

INSTALLED_APPS = [
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.humanize",
    "django.contrib.gis",
    # all-auth
    "django.contrib.sites",
    # overrides allauth templates
    # must precede allauth
    "openwisp_users.accounts",
    "allauth",
    "allauth.account",
    "allauth.socialaccount",
    "django_extensions",
    # openwisp2 modules
    "openwisp_users",
    "openwisp_controller.pki",
    "openwisp_controller.config",
    "openwisp_controller.geo",
    "openwisp_controller.connection",
    "openwisp_monitoring.monitoring",
    "openwisp_monitoring.device",
    "openwisp_monitoring.check",
    "nested_admin",
    "openwisp_notifications",
    "flat_json_widget",
    "openwisp_ipam",
    # openwisp2 admin theme
    # (must be loaded here)
    "openwisp_utils.admin_theme",
    "openwisp_utils.metric_collection",
    "admin_auto_filters",
    # admin
    "django.contrib.admin",
    "django.forms",
    # other dependencies
    "sortedm2m",
    "reversion",
    "leaflet",
    "rest_framework",
    "rest_framework_gis",
    "rest_framework.authtoken",
    "django_filters",
    "drf_yasg",
    "channels",
    "pipeline",
    "import_export",
    "djcelery_email",
]

EXTENDED_APPS = [
    "django_x509",
    "django_loci",
]



AUTH_USER_MODEL = "openwisp_users.User"
SITE_ID = 1
LOGIN_REDIRECT_URL = "admin:index"
ACCOUNT_LOGOUT_REDIRECT_URL = LOGIN_REDIRECT_URL
ACCOUNT_EMAIL_CONFIRMATION_ANONYMOUS_REDIRECT_URL = "email_confirmation_success"
ACCOUNT_EMAIL_CONFIRMATION_AUTHENTICATED_REDIRECT_URL = "email_confirmation_success"

STATICFILES_FINDERS = [
    "django.contrib.staticfiles.finders.FileSystemFinder",
    "django.contrib.staticfiles.finders.AppDirectoriesFinder",
    "openwisp_utils.staticfiles.DependencyFinder",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "allauth.account.middleware.AccountMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
    "pipeline.middleware.MinifyHTMLMiddleware",
]

AUTHENTICATION_BACKENDS = [
    "openwisp_users.backends.UsersAuthenticationBackend",
]


ROOT_URLCONF = "openwisp2.urls"
OPENWISP_USERS_AUTH_API = True


CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels_redis.core.RedisChannelLayer",
        "CONFIG": {
            "hosts": [("localhost", 6379)],
            "group_expiry": 3600,
        },
    },
}
ASGI_APPLICATION = "openwisp2.routing.application"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [os.path.join(BASE_DIR, "templates")],
        "OPTIONS": {
            "loaders": [
                (
                    "django.template.loaders.cached.Loader",
                    [
                        "django.template.loaders.filesystem.Loader",
                        "openwisp_utils.loaders.DependencyLoader",
                        "django.template.loaders.app_directories.Loader",
                    ],
                ),
            ],
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
                "openwisp_utils.admin_theme.context_processor.menu_items",
                "openwisp_utils.admin_theme.context_processor.admin_theme_settings",
                "openwisp_notifications.context_processors.notification_api_settings",
            ],
        },
    },
]

# Run celery in eager mode using in-memory broker while running tests
if not TESTING:
    CELERY_TASK_ACKS_LATE = True
    CELERY_BROKER_URL = "redis://localhost:6379/3"
else:
    CELERY_TASK_ALWAYS_EAGER = True
    CELERY_TASK_EAGER_PROPAGATES = True
    CELERY_BROKER_URL = "memory://"

# Workaround for stalled migrate command
CELERY_BROKER_TRANSPORT_OPTIONS = {
    "max_retries": 10,
}

CELERY_BEAT_SCHEDULE = {
    "delete_old_notifications": {
        "task": "openwisp_notifications.tasks.delete_old_notifications",
        "schedule": crontab(**{ 'hour': 0, 'minute': 0 }),
        "args": (90,),
    },
    "run_checks": {
        "task": "openwisp_monitoring.check.tasks.run_checks",
        "schedule": timedelta(minutes=5),
    },
}

CELERY_TASK_ROUTES = {
    # network operations, executed in the "network" queue
    "openwisp_controller.connection.tasks.*": {"queue": "network"},
    # monitoring checks are executed in a dedicated "monitoring" queue
    "openwisp_monitoring.check.tasks.perform_check": {"queue": "monitoring"},
    "openwisp_monitoring.monitoring.tasks.migrate_timeseries_database": {
        "queue": "monitoring"
    },
    # all other tasks are routed to the default queue (named "celery")
}

# FOR DJANGO REDIS
CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": "redis://localhost:6379/1",
        "OPTIONS": {
            "CLIENT_CLASS": "django_redis.client.DefaultClient",
        },
    }
}

SESSION_ENGINE = "django.contrib.sessions.backends.cache"
SESSION_CACHE_ALIAS = "default"
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True

FORM_RENDERER = "django.forms.renderers.TemplatesSetting"

WSGI_APPLICATION = "openwisp2.wsgi.application"

# Database
# https://docs.djangoproject.com/en/1.9/ref/settings/#databases

DATABASES = {
    "default": {
        "ENGINE": "openwisp_utils.db.backends.spatialite",
        "NAME": "/opt/openwisp2/db.sqlite3",
        "OPTIONS": {
    "timeout": 10
},
    }
}

SPATIALITE_LIBRARY_PATH = "mod_spatialite.so"

# Password validation
# https://docs.djangoproject.com/en/1.9/ref/settings/#auth-password-validators

AUTH_PASSWORD_VALIDATORS = [
    {
        "NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"
    },
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
    {"NAME": "openwisp_users.password_validation.PasswordReuseValidator"},
]

# Internationalization
# https://docs.djangoproject.com/en/1.9/topics/i18n/

LANGUAGE_CODE = "en-gb"
TIME_ZONE = "UTC"
USE_TZ = True

# Static files (CSS, JavaScript, Images)
# https://docs.djangoproject.com/en/1.9/howto/static-files/

STATICFILES_DIRS = [os.path.join(BASE_DIR, "static_custom")]
STATIC_ROOT = os.path.join(BASE_DIR, "static")
MEDIA_ROOT = os.path.join(BASE_DIR, "media")
STATIC_URL = "/static/"
MEDIA_URL = "/media/"


# django x509 settings
DJANGO_X509_DEFAULT_CERT_VALIDITY = 1825
DJANGO_X509_DEFAULT_CA_VALIDITY = 3650

LEAFLET_CONFIG = {}
# always disable RESET_VIEW button
LEAFLET_CONFIG["RESET_VIEW"] = False

# Set default email
DEFAULT_FROM_EMAIL = "openwisp2@91.99.73.243"
EMAIL_BACKEND = "djcelery_email.backends.CeleryEmailBackend"
EMAIL_TIMEOUT = 10
# See http://docs.djangoproject.com/en/dev/topics/logging for
# more details on how to customize your logging configuration.
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "filters": {
        "require_debug_false": {
            "()": "django.utils.log.RequireDebugFalse",
        },
        "require_debug_true": {
            "()": "django.utils.log.RequireDebugTrue",
        },
    },
    "formatters": {
        "simple": {"format": "[%(levelname)s] %(message)s"},
        "verbose": {
            "format": "[%(levelname)s %(asctime)s] module: %(module)s, process: %(process)d, thread: %(thread)d\n%(message)s\n"
        },
    },
    "handlers": {
        "console": {
            "level": "DEBUG",
            "class": "logging.StreamHandler",
            "filters": ["require_debug_true"],
            "formatter": "simple",
        },
        "mail_admins": {
            "level": "ERROR",
            "filters": ["require_debug_false"],
            "class": "django.utils.log.AdminEmailHandler",
        },
        "main_log": {
            "level": "INFO",
            "class": "logging.handlers.RotatingFileHandler",
            "filename": os.path.join(BASE_DIR, "log/openwisp2.log"),
            "maxBytes": 15728640,
            "backupCount": 3,
            "formatter": "verbose",
        },
        "null": {
            "level": "DEBUG",
            "class": "logging.NullHandler",
        },
    },
    "root": {
        "level": "INFO",
        "handlers": [
            "main_log",
            "console",
            "mail_admins",
        ],
    },
    "loggers": {
        "django.security.DisallowedHost": {
            "handlers": ["main_log"],
            "propagate": False,
        }
    },
}

# HTML minification with django pipeline
PIPELINE = {"PIPELINE_ENABLED": True}
# static files minification and invalidation with django-compress-staticfiles
STORAGES = {
    "staticfiles": {
        "BACKEND": "openwisp_utils.storage.CompressStaticFilesStorage",
    },
}
# GZIP compression is handled by nginx
BROTLI_STATIC_COMPRESSION = False
GZIP_STATIC_COMPRESSION = False


TIMESERIES_DATABASE = {
    "BACKEND": "openwisp_monitoring.db.backends.influxdb",
    "USER": "openwisp",
    "PASSWORD": "openwisp",
    "NAME": "openwisp2",
    "HOST": "localhost",
    "PORT": "8086",
}
OPENWISP_MONITORING_DEFAULT_RETENTION_POLICY = (
    "26280h0m0s"
)




TEST_RUNNER = "openwisp_utils.metric_collection.tests.runner.MockRequestPostRunner"
# --- OpenWISP Controller API auth classes ---
OPENWISP_CONTROLLER_API_AUTHENTICATION_CLASSES = (
    'openwisp_controller.api.authentication.DeviceKeyAuthentication',
    'rest_framework.authentication.TokenAuthentication',
    'rest_framework.authentication.SessionAuthentication',
)
# --- OpenWISP Controller API auth classes ---
OPENWISP_CONTROLLER_API_AUTHENTICATION_CLASSES = (
    'openwisp_controller.api.authentication.DeviceKeyAuthentication',
    'rest_framework.authentication.TokenAuthentication',
    'rest_framework.authentication.SessionAuthentication',
)

# Ensure DRF uses DeviceKey + Token + Session (fallback)
