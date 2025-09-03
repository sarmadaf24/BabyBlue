#!/usr/bin/env bash
set -euo pipefail

# ===== Inputs =====
read -rp "Destination domain (e.g. example.com): " BB_DOMAIN
read -rp "Email for SSL: " BB_EMAIL
read -rp "Superuser username [admin]: " BB_SU
read -rsp "Superuser password [admin123]: " BB_SP; echo
read -rp "Source SSH (e.g. root@1.2.3.4): " SRC
read -rp "Source SSH port [22]: " SSH_PORT
BB_SU="${BB_SU:-admin}"; BB_SP="${BB_SP:-admin123}"; SSH_PORT="${SSH_PORT:-22}"
[ -z "${BB_EMAIL:-}" ] && BB_EMAIL="admin@${BB_DOMAIN}"
export DEBIAN_FRONTEND=noninteractive
APP="/opt/openwisp2"

# ===== System deps =====
apt-get update -y >/dev/null
apt-get install -y --no-install-recommends \
  git curl ca-certificates \
  apache2 certbot python3-certbot-apache \
  postgresql redis-server python3-venv \
  freeradius freeradius-utils openvpn wireguard \
  ufw iptables-persistent \
  build-essential python3-dev pkg-config libpq-dev libssl-dev libffi-dev zlib1g-dev \
  gdal-bin libgdal-dev libgeos-dev libspatialite-dev libsqlite3-mod-spatialite \
  libcairo2 libpango-1.0-0 libpangocairo-1.0-0 gnupg lsb-release >/dev/null || true
systemctl enable --now redis-server postgresql >/dev/null 2>&1 || true

# ===== Apache + SSL =====
a2enmod ssl proxy proxy_http headers rewrite >/dev/null 2>&1 || true
echo "ServerName ${BB_DOMAIN}" >/etc/apache2/conf-available/servername.conf
a2enconf servername >/dev/null 2>&1 || true
# HTTP → HTTPS (ACME passthrough)
cat >/etc/apache2/sites-available/openwisp-http.conf <<HTTPV
<VirtualHost *:80>
  ServerName ${BB_DOMAIN}
  RewriteEngine On
  RewriteRule ^/\.well-known/acme-challenge/ - [L]
  RedirectMatch 302 ^/(.*)$ https://${BB_DOMAIN}/\$1
</VirtualHost>
HTTPV
a2ensite openwisp-http.conf >/dev/null 2>&1 || true
a2dissite 000-default >/dev/null 2>&1 || true
apache2ctl configtest >/dev/null && systemctl reload apache2 || systemctl restart apache2 || true

# Issue cert (standalone fallback if missing)
if [ ! -s "/etc/letsencrypt/live/${BB_DOMAIN}/fullchain.pem" ]; then
  systemctl stop apache2 || true
  certbot certonly --standalone -d "${BB_DOMAIN}" --non-interactive --agree-tos -m "${BB_EMAIL}" || true
  systemctl start apache2 || true
fi

# HTTPS vhost with static/media
cat >/etc/apache2/sites-available/openwisp-ssl.conf <<SSLV
<VirtualHost *:443>
  ServerName ${BB_DOMAIN}
  SSLEngine on
  SSLCertificateFile /etc/letsencrypt/live/${BB_DOMAIN}/fullchain.pem
  SSLCertificateKeyFile /etc/letsencrypt/live/${BB_DOMAIN}/privkey.pem

  Alias /static/ ${APP}/static/
  Alias /media/  ${APP}/media/
  <Directory ${APP}/static>
    Require all granted
  </Directory>
  <Directory ${APP}/media>
    Require all granted
  </Directory>

  ProxyPreserveHost On
  RequestHeader set X-Forwarded-Proto https
  ProxyPass /static !
  ProxyPass /media !
  ProxyPass / http://127.0.0.1:8001/
  ProxyPassReverse / http://127.0.0.1:8001/

  ErrorLog \${APACHE_LOG_DIR}/openwisp_error.log
  CustomLog \${APACHE_LOG_DIR}/openwisp_access.log combined
</VirtualHost>
SSLV
a2ensite openwisp-ssl.conf >/dev/null 2>&1 || true
apache2ctl configtest >/dev/null && systemctl reload apache2 || systemctl restart apache2 || true

# ===== App skeleton & env =====
install -d -m755 "${APP}/openwisp2" "${APP}/log" /root/babyblue_inventory
:> "${APP}/log/openwisp2.log"; chown -R www-data:www-data "${APP}/log"
# Pull settings & env from source (best-effort)
scp -P "${SSH_PORT}" -q "${SRC}:${APP}/openwisp2/settings.py" "${APP}/openwisp2/settings.py" || true
scp -P "${SSH_PORT}" -q "${SRC}:/root/babyblue_inventory/openwisp_env.sh" /root/babyblue_inventory/openwisp_env.sh || true
[ -f /root/babyblue_inventory/openwisp_env.sh ] && sed -i "s#^OPENWISP_URL=.*#OPENWISP_URL=https://${BB_DOMAIN}#g" /root/babyblue_inventory/openwisp_env.sh || true
chmod 600 /root/babyblue_inventory/openwisp_env.sh 2>/dev/null || true

# Ensure manage.py & wsgi.py
[ -f "${APP}/openwisp2/__init__.py" ] || :> "${APP}/openwisp2/__init__.py"
[ -f "${APP}/openwisp2/wsgi.py" ] || cat > "${APP}/openwisp2/wsgi.py" <<WSGI
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "openwisp2.settings")
application = get_wsgi_application()
WSGI
[ -f "${APP}/manage.py" ] || cat > "${APP}/manage.py" <<MNG
#!/usr/bin/env python3
import os, sys
if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "openwisp2.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
MNG
chmod +x "${APP}/manage.py"

# ===== Python venv + packages (pinned & complete) =====
python3 -m venv "${APP}/venv" || true
. "${APP}/venv/bin/activate"
python -m pip install -U "pip" "setuptools<81" wheel >/dev/null
# Base
pip install -q "Django>=4.2,<4.3" "djangorestframework>=3.14,<3.15" "django-filter>=23,<24" \
  "celery>=5.3,<5.4" "django-celery-results>=2.5,<2.6" "django-celery-beat>=2.6,<2.7" \
  "channels>=4,<5" "channels-redis>=4,<5" "django-redis>=5,<7" "django-pipeline>=4,<5" \
  "redis" "psycopg2-binary" "gunicorn"
# OpenWISP core from git (no deps) + required extras
pip install -q "git+https://github.com/openwisp/netjsonconfig@1.2#egg=netjsonconfig"
for p in openwisp-users openwisp-controller openwisp-ipam openwisp-monitoring openwisp-notifications; do
  pip install -q --no-deps "git+https://github.com/openwisp/${p}@1.2#egg=${p}"
done
pip install -q "openwisp-utils @ git+https://github.com/openwisp/openwisp-utils@1.2"
pip install -q "https://github.com/openwisp/django-loci/tarball/1.2" \
               "https://github.com/openwisp/django-x509/tarball/1.3" \
               "https://github.com/openwisp/django-rest-framework-gis/tarball/1.2"
pip install -q "drf-yasg==1.21.7" "jsonfield>=2.1.0" "markdown==3.8.2" \
               "django-extensions>=3.2,<4.2" "django-allauth[socialaccount]==65.8.1" "django-organizations==2.5.0" \
               "django-phonenumber-field==8.1.0" "phonenumbers==9.0.13" "django-sesame==3.2.3" \
               "django-cache-memoize==0.2.1" "django-flat-json-widget==0.3.1" "django-import-export==4.1.1" \
               "django-sortedm2m==4.0.0" "django-taggit==6.0.0" "netaddr==1.3.0" "paramiko[ed25519]==3.5.1" \
               "scp==0.15.0" "shortuuid==1.0.13" "openpyxl==3.1.5" "django-nested-admin==4.1.3" \
               "influxdb==5.3.2" "django-celery-email==3.0.0"

# ===== Settings patch (hosts/ssl proxy) =====
SETTINGS="${APP}/openwisp2/settings.py"
if [ -f "$SETTINGS" ]; then
  cat >> "$SETTINGS" <<EOP
# --- GitOps patch ---
ALLOWED_HOSTS = list(set((ALLOWED_HOSTS if "ALLOWED_HOSTS" in globals() else []) + ["${BB_DOMAIN}","127.0.0.1","localhost"]))
CSRF_TRUSTED_ORIGINS = list(set((CSRF_TRUSTED_ORIGINS if "CSRF_TRUSTED_ORIGINS" in globals() else []) + ["https://${BB_DOMAIN}"]))
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO","https")
USE_X_FORWARDED_HOST = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
EOP
fi

# ===== DB sync (best-effort) =====
mkdir -p /root/dbsync
# Prefer dumpdata → loaddata
if ssh -p "${SSH_PORT}" "${SRC}" test -x "${APP}/venv/bin/python" 2>/dev/null; then
  ssh -p "${SSH_PORT}" "${SRC}" "${APP}/venv/bin/python ${APP}/manage.py dumpdata --natural-foreign --natural-primary --exclude contenttypes --exclude auth.Permission --indent 2" > /root/dbsync/openwisp.json || true
  if [ -s /root/dbsync/openwisp.json ]; then
    "${APP}/venv/bin/python" "${APP}/manage.py" loaddata /root/dbsync/openwisp.json || true
  fi
fi

# ===== Django ops =====
"${APP}/venv/bin/python" "${APP}/manage.py" migrate --noinput || true
DJANGO_SUPERUSER_USERNAME="${BB_SU}" DJANGO_SUPERUSER_EMAIL="${BB_EMAIL}" DJANGO_SUPERUSER_PASSWORD="${BB_SP}" \
  "${APP}/venv/bin/python" "${APP}/manage.py" createsuperuser --noinput || true
"${APP}/venv/bin/python" "${APP}/manage.py" collectstatic --noinput || true

# ===== Gunicorn (systemd) =====
cat >/etc/systemd/system/gunicorn.service <<UNIT
[Unit]
Description=Gunicorn for OpenWISP
After=network.target
[Service]
User=www-data
Group=www-data
WorkingDirectory=${APP}
Environment=PATH=${APP}/venv/bin
ExecStart=${APP}/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:8001 openwisp2.wsgi:application
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now gunicorn

# ===== UFW (basic) =====
ufw --force enable || true
for p in 22/tcp 80/tcp 443/tcp; do ufw allow "$p" || true; done
ufw allow 1194/udp || true
ufw allow 51820/udp || true

# ===== Healthchecks =====
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${BB_DOMAIN}")
HTTPS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${BB_DOMAIN}")
ADMIN_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${BB_DOMAIN}/admin/login/")
GUNI_STATUS=inactive; systemctl is-active gunicorn >/dev/null 2>&1 && GUNI_STATUS=active

echo "HTTP=${HTTP_CODE}"
echo "HTTPS=${HTTPS_CODE}"
echo "ADMIN=${ADMIN_CODE}"
echo "GUNICORN=${GUNI_STATUS}"
echo "Admin: https://${BB_DOMAIN}/admin/"
[ -f /root/babyblue_inventory/openwisp_env.sh ] && echo "API base: https://${BB_DOMAIN}/api/v1/ (Bearer token in /root/babyblue_inventory/openwisp_env.sh)" || true
printf "\033[1;32m%s\033[0m\n" "BlueHub net.isp.vpn"
printf "\033[1;32m%s\033[0m\n" "Done Join & Enjoy"
