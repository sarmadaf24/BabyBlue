#!/usr/bin/env bash
set -euo pipefail

read -rp "Destination domain (e.g. example.com): " BB_DOMAIN
read -rp "Email for SSL: " BB_EMAIL
read -rp "Superuser username [admin]: " BB_SU
read -rsp "Superuser password [admin123]: " BB_SP; echo
read -rp "Source SSH (e.g. root@1.2.3.4): " SRC
read -rp "Source SSH port [22]: " SSH_PORT
BB_SU="${BB_SU:-admin}"; BB_SP="${BB_SP:-admin123}"; SSH_PORT="${SSH_PORT:-22}"
[ -z "${BB_EMAIL:-}" ] && BB_EMAIL="admin@${BB_DOMAIN}"
export DEBIAN_FRONTEND=noninteractive

apt-get update -y >/dev/null
apt-get install -y git curl rsync openssh-client ca-certificates \
  apache2 certbot python3-certbot-apache postgresql redis-server python3-venv \
  freeradius freeradius-utils openvpn wireguard ufw iptables-persistent \
  gdal-bin libgdal-dev libgeos-dev libspatialite-dev libsqlite3-mod-spatialite \
  libcairo2 libpango-1.0-0 libpangocairo-1.0-0 gnupg lsb-release >/dev/null || true

if ! dpkg -s influxdb >/dev/null 2>&1; then
  curl -fsSL https://repos.influxdata.com/influxdata-archive_compat.key | gpg --dearmor >/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg || true
  . /etc/os-release
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" >/etc/apt/sources.list.d/influxdata.list || true
  apt-get update -y >/dev/null || true
  apt-get install -y influxdb || true
fi
systemctl enable --now influxdb redis-server postgresql >/dev/null 2>&1 || true

a2enmod ssl proxy proxy_http headers rewrite >/dev/null 2>&1 || true
echo "ServerName ${BB_DOMAIN}" >/etc/apache2/conf-available/servername.conf
a2enconf servername >/dev/null 2>&1 || true
cat >/etc/apache2/sites-available/openwisp.conf <<EOV
<VirtualHost *:80>
    ServerName ${BB_DOMAIN}
    RewriteEngine On
    RewriteRule ^/\.well-known/acme-challenge/ - [L]
    RedirectMatch 302 ^/(.*)$ https://${BB_DOMAIN}/\$1
</VirtualHost>
EOV
a2ensite openwisp.conf >/dev/null 2>&1 || true
a2dissite openwisp-ssl.conf >/dev/null 2>&1 || true
apache2ctl configtest >/dev/null && systemctl reload apache2 || systemctl restart apache2 || true

if [ ! -s "/etc/letsencrypt/live/${BB_DOMAIN}/fullchain.pem" ]; then
  systemctl stop apache2 || true
  certbot certonly --standalone -d "${BB_DOMAIN}" --non-interactive --agree-tos -m "${BB_EMAIL}" || true
  systemctl start apache2 || true
fi

APP="/opt/openwisp2"
install -d -m 755 "${APP}/log" "${APP}"
:> "${APP}/log/openwisp2.log"; chown -R www-data:www-data "${APP}/log"

rsync -a -e "ssh -p ${SSH_PORT}" --delete "${SRC}:${APP}/" "${APP}/" || true

install -d -m 755 "${APP}/openwisp2"
[ -f "${APP}/openwisp2/__init__.py" ] || :> "${APP}/openwisp2/__init__.py"
[ -f "${APP}/openwisp2/wsgi.py" ] || cat > "${APP}/openwisp2/wsgi.py" <<PY
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "openwisp2.settings")
application = get_wsgi_application()
PY
[ -f "${APP}/manage.py" ] || cat > "${APP}/manage.py" <<PY
#!/usr/bin/env python3
import os, sys
if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "openwisp2.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
PY
chmod +x "${APP}/manage.py"

install -d -m 700 /root/babyblue_inventory
scp -P "${SSH_PORT}" -q "${SRC}:/root/babyblue_inventory/openwisp_env.sh" /root/babyblue_inventory/openwisp_env.sh || true
[ -f /root/babyblue_inventory/openwisp_env.sh ] && sed -i "s#^OPENWISP_URL=.*#OPENWISP_URL=https://${BB_DOMAIN}#g" /root/babyblue_inventory/openwisp_env.sh || true
chmod 600 /root/babyblue_inventory/openwisp_env.sh 2>/dev/null || true

for u in gunicorn.service celery.service celery@worker.service celery-beat.service openwisp.service; do
  rsync -a -e "ssh -p ${SSH_PORT}" "${SRC}:/etc/systemd/system/${u}" "/etc/systemd/system/${u}" 2>/dev/null || true
done
systemctl daemon-reload || true

TMP_ETC="/tmp/src_web_$$"; mkdir -p "${TMP_ETC}"
rsync -a -e "ssh -p ${SSH_PORT}" "${SRC}:/etc/apache2/sites-available/" "${TMP_ETC}/" 2>/dev/null || true
SRC_DOM="$(ssh -p "${SSH_PORT}" "${SRC}" grep
