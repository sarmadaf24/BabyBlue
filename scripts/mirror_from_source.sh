#!/usr/bin/env bash
set -euo pipefail

# ===== inputs =====
read -rp "Destination domain (e.g. example.com): " BB_DOMAIN
read -rp "Email for SSL: " BB_EMAIL
read -rp "Superuser username [admin]: " BB_SU
read -rsp "Superuser password [admin123]: " BB_SP; echo
read -rp "Source SSH (e.g. root@1.2.3.4): " SRC
read -rp "Source SSH port [22]: " SSH_PORT
BB_SU="${BB_SU:-admin}"; BB_SP="${BB_SP:-admin123}"; SSH_PORT="${SSH_PORT:-22}"
[ -z "${BB_EMAIL:-}" ] && BB_EMAIL="admin@${BB_DOMAIN}"

export DEBIAN_FRONTEND=noninteractive

# ===== base deps =====
apt-get update -y >/dev/null
apt-get install -y git curl rsync openssh-client ca-certificates \
  apache2 certbot python3-certbot-apache postgresql redis-server python3-venv \
  freeradius freeradius-utils openvpn wireguard ufw iptables-persistent \
  gdal-bin libgdal-dev libgeos-dev libspatialite-dev libsqlite3-mod-spatialite \
  libcairo2 libpango-1.0-0 libpangocairo-1.0-0 gnupg lsb-release >/dev/null

# InfluxDB (best-effort for 1.x/compat)
if ! dpkg -s influxdb >/dev/null 2>&1; then
  curl -fsSL https://repos.influxdata.com/influxdata-archive_compat.key | gpg --dearmor >/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg || true
  . /etc/os-release
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" >/etc/apt/sources.list.d/influxdata.list || true
  apt-get update -y >/dev/null || true
  apt-get install -y influxdb || true
fi
systemctl enable --now influxdb >/dev/null 2>&1 || true
systemctl enable --now redis-server >/dev/null 2>&1 || true
systemctl enable --now postgresql >/dev/null 2>&1 || true

# ===== apache vhosts (http first for ACME) =====
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

# ===== certbot (standalone fallback) =====
if [ ! -s "/etc/letsencrypt/live/${BB_DOMAIN}/fullchain.pem" ]; then
  systemctl stop apache2 || true
  certbot certonly --standalone -d "${BB_DOMAIN}" --non-interactive --agree-tos -m "${BB_EMAIL}" || true
  systemctl start apache2 || true
fi

# ===== rsync from source =====
APP="/opt/openwisp2"
install -d -m 755 "${APP}/log" "${APP}"
:> "${APP}/log/openwisp2.log"; chown -R www-data:www-data "${APP}/log"

# copy app (venv included if present)
rsync -a -e "ssh -p ${SSH_PORT}" --delete "${SRC}:${APP}/" "${APP}/" || true
# ensure skeleton if missing
install -d -m 755 "${APP}/openwisp2"; [ -f "${APP}/openwisp2/__init__.py" ] || :> "${APP}/openwisp2/__init__.py"
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

# copy env inventory
install -d -m 700 /root/babyblue_inventory
scp -P "${SSH_PORT}" -q "${SRC}:/root/babyblue_inventory/openwisp_env.sh" /root/babyblue_inventory/openwisp_env.sh || true
[ -f /root/babyblue_inventory/openwisp_env.sh ] && sed -i "s#^OPENWISP_URL=.*#OPENWISP_URL=https://${BB_DOMAIN}#g" /root/babyblue_inventory/openwisp_env.sh || true
chmod 600 /root/babyblue_inventory/openwisp_env.sh 2>/dev/null || true

# copy services (gunicorn/celery/openwisp custom)
for u in gunicorn.service celery.service celery@worker.service celery-beat.service openwisp.service; do
  rsync -a -e "ssh -p ${SSH_PORT}" "${SRC}:/etc/systemd/system/${u}" "/etc/systemd/system/${u}" 2>/dev/null || true
done
systemctl daemon-reload || true

# web config from source then retarget domain + cert paths
TMP_ETC="/tmp/src_web_$$"
mkdir -p "${TMP_ETC}"
rsync -a -e "ssh -p ${SSH_PORT}" "${SRC}:/etc/apache2/sites-available/" "${TMP_ETC}/" 2>/dev/null || true
SRC_DOM="$(ssh -p "${SSH_PORT}" "${SRC}" "grep -RhoE \"ServerName\\s+\\S+\" /etc/apache2/sites-available/*.conf 2>/dev/null | awk \"{print \\$2}\" | head -n1 || true")"
[ -z "${SRC_DOM:-}" ] && SRC_DOM="${BB_DOMAIN}"
if compgen -G "${TMP_ETC}/*.conf" >/dev/null; then
  cp -a "${TMP_ETC}/"*".conf" /etc/apache2/sites-available/
  sed -i "s#${SRC_DOM//./\\.}#${BB_DOMAIN}#g" /etc/apache2/sites-available/*.conf || true
  sed -i "s#/etc/letsencrypt/live/.*/fullchain.pem#/etc/letsencrypt/live/${BB_DOMAIN}/fullchain.pem#g" /etc/apache2/sites-available/*.conf || true
  sed -i "s#/etc/letsencrypt/live/.*/privkey.pem#/etc/letsencrypt/live/${BB_DOMAIN}/privkey.pem#g" /etc/apache2/sites-available/*.conf || true
fi

# ===== database dump/restore =====
mkdir -p /root/dbsync
ssh -p "${SSH_PORT}" "${SRC}" "sudo -u postgres pg_dump -Fc openwisp" > /root/dbsync/openwisp.dump || true
if [ -s /root/dbsync/openwisp.dump ]; then
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname=openwisp;" | grep -q 1 || sudo -u postgres createdb openwisp
  sudo -u postgres pg_restore -j 2 -c -d openwisp /root/dbsync/openwisp.dump || true
fi

# ===== RADIUS / VPN / UFW =====
rsync -a -e "ssh -p ${SSH_PORT}" "${SRC}:/etc/freeradius/3.0/" "/etc/freeradius/3.0/" 2>/dev/null || true
systemctl enable --now freeradius >/dev/null 2>&1 || systemctl enable --now freeradius.service >/dev/null 2>&1 || true

rsync -a -e "ssh -p ${SSH_PORT}" "${SRC}:/etc/openvpn/" "/etc/openvpn/" 2>/dev/null || true
systemctl enable --now openvpn >/dev/null 2>&1 || systemctl enable --now openvpn-server@server >/dev/null 2>&1 || true

rsync -a -e "ssh -p ${SSH_PORT}" "${SRC}:/etc/wireguard/" "/etc/wireguard/" 2>/dev/null || true
systemctl enable --now wg-quick@wg0 >/dev/null 2>&1 || true

ufw --force enable || true
for p in 22/tcp 80/tcp 443/tcp; do ufw allow "$p" || true; done
ufw allow 1194/udp || true
ufw allow 51820/udp || true

# ===== python env =====
if [ ! -x "${APP}/venv/bin/python" ]; then
  python3 -m venv "${APP}/venv"
  . "${APP}/venv/bin/activate"
  pip install --upgrade pip >/dev/null
  if [ -f "${APP}/requirements.txt" ]; then pip install -r "${APP}/requirements.txt"; else pip install openwisp-controller openwisp-ipam openwisp-monitoring openwisp-users netjsonconfig django psycopg2-binary gunicorn; fi
else
  . "${APP}/venv/bin/activate" || true
  pip install --upgrade pip >/dev/null || true
fi

# ===== django ops =====
if [ -f "${APP}/manage.py" ]; then
  "${APP}/venv/bin/python" "${APP}/manage.py" migrate --noinput || true
  DJANGO_SUPERUSER_USERNAME="${BB_SU}" DJANGO_SUPERUSER_EMAIL="${BB_EMAIL}" DJANGO_SUPERUSER_PASSWORD="${BB_SP}" "${APP}/venv/bin/python" "${APP}/manage.py" createsuperuser --noinput || true
  "${APP}/venv/bin/python" "${APP}/manage.py" collectstatic --noinput || true
fi

# ===== gunicorn + apache ssl vhost =====
cat >/etc/systemd/system/gunicorn.service <<EOS
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
EOS
systemctl daemon-reload
systemctl enable --now gunicorn

cat >/etc/apache2/sites-available/openwisp-ssl.conf <<EOV
<VirtualHost *:443>
    ServerName ${BB_DOMAIN}
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${BB_DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${BB_DOMAIN}/privkey.pem
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto https
    ProxyPass / http://127.0.0.1:8001/
    ProxyPassReverse / http://127.0.0.1:8001/
    ErrorLog \${APACHE_LOG_DIR}/openwisp_error.log
    CustomLog \${APACHE_LOG_DIR}/openwisp_access.log combined
</VirtualHost>
EOV
a2ensite openwisp-ssl.conf >/dev/null 2>&1 || true
apache2ctl configtest >/dev/null && systemctl reload apache2 || systemctl restart apache2

# ===== healthchecks =====
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${BB_DOMAIN}")
HTTPS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${BB_DOMAIN}")
ADMIN_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${BB_DOMAIN}/admin/login/")
GUNI_STATUS=$(systemctl is-active gunicorn >/dev/null 2>&1 && echo active || echo inactive)
RAD_STATUS=$(systemctl is-active freeradius >/dev/null 2>&1 && echo active || echo inactive)
OVPN_STATUS=$(systemctl is-active openvpn >/dev/null 2>&1 || systemctl is-active openvpn-server@server >/dev/null 2>&1 && echo active || echo inactive)
WG_STATUS=$(systemctl is-active wg-quick@wg0 >/dev/null 2>&1 && echo active || echo inactive)
echo "HTTP_STATUS=${HTTP_CODE}"
echo "HTTPS_STATUS=${HTTPS_CODE}"
echo "ADMIN_STATUS=${ADMIN_CODE}"
echo "GUNICORN=${GUNI_STATUS}"
echo "RADIUS=${RAD_STATUS}"
echo "OPENVPN=${OVPN_STATUS}"
echo "WIREGUARD=${WG_STATUS}"
echo "Admin: https://${BB_DOMAIN}/admin/"
[ -f /root/babyblue_inventory/openwisp_env.sh ] && echo "API base: https://${BB_DOMAIN}/api/v1/ (Bearer token in /root/babyblue_inventory/openwisp_env.sh)" || true
printf "\033[1;32m%s\033[0m\n" "BlueHub net.isp.vpn"
printf "\033[1;32m%s\033[0m\n" "Done Join & Enjoy"
