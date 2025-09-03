#!/usr/bin/env bash
set -euo pipefail
read -rp "Domain (e.g. example.com): " BB_DOMAIN
read -rp "Email for SSL: " BB_EMAIL
read -rp "Superuser username [admin]: " BB_SU
read -rsp "Superuser password [admin123]: " BB_SP; echo
BB_SU="${BB_SU:-admin}"; BB_SP="${BB_SP:-admin123}"; [ -z "${BB_EMAIL:-}" ] && BB_EMAIL="admin@${BB_DOMAIN}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y git curl ca-certificates apache2 certbot python3-certbot-apache postgresql redis-server python3-venv >/dev/null

# Apache HTTP (redirect to HTTPS + ACME pass-through)
a2enmod ssl proxy proxy_http headers rewrite >/dev/null 2>&1 || true
cat > /etc/apache2/sites-available/openwisp.conf <<EOV
<VirtualHost *:80>
    ServerName ${BB_DOMAIN}
    RewriteEngine On
    RewriteRule ^/\.well-known/acme-challenge/ - [L]
    RedirectMatch 302 ^/(.*)$ https://${BB_DOMAIN}/\$1
</VirtualHost>
EOV
a2ensite openwisp.conf >/dev/null 2>&1 || true
apachectl configtest >/dev/null && systemctl reload apache2 || systemctl restart apache2 || true

# SSL
certbot --apache -d "${BB_DOMAIN}" --non-interactive --agree-tos -m "${BB_EMAIL}" || true

# App
APP="/opt/openwisp2"
install -d -m 755 "$APP/openwisp2"
[ -f "$APP/openwisp2/__init__.py" ] || :> "$APP/openwisp2/__init__.py"
[ -f "$APP/openwisp2/wsgi.py" ] || cat > "$APP/openwisp2/wsgi.py" <<PY
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "openwisp2.settings")
application = get_wsgi_application()
PY
[ -f "$APP/manage.py" ] || cat > "$APP/manage.py" <<PY
#!/usr/bin/env python3
import os, sys
if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "openwisp2.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
PY
chmod +x "$APP/manage.py"

python3 -m venv "$APP/venv"
. "$APP/venv/bin/activate"
pip install --upgrade pip >/dev/null
if [ -f requirements.txt ]; then pip install -r requirements.txt; else
  pip install openwisp-controller openwisp-ipam openwisp-monitoring openwisp-users netjsonconfig django psycopg2-binary gunicorn
fi

# Settings/env/state from repo if present
[ -f config/app/settings.py ] && install -m 644 -D config/app/settings.py "$APP/openwisp2/settings.py" || true
[ -d state/files/static ] && mkdir -p "$APP/static" && cp -a state/files/static/. "$APP/static/" || true
[ -d state/files/media ] && mkdir -p "$APP/media" && cp -a state/files/media/. "$APP/media/" || true

# Inventory env
mkdir -p /root/babyblue_inventory
if [ -f inventory/openwisp_env.sh ]; then
  install -m 600 -D inventory/openwisp_env.sh /root/babyblue_inventory/openwisp_env.sh
  sed -i "s#^OPENWISP_URL=.*#OPENWISP_URL=https://${BB_DOMAIN}#g" /root/babyblue_inventory/openwisp_env.sh || true
fi

# DB restore (optional)
if [ -f state/db/openwisp.dump ]; then
  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl start postgresql >/dev/null 2>&1 || true
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname=openwisp;" | grep -q 1 || sudo -u postgres createdb openwisp
  sudo -u postgres pg_restore -j 2 -c -d openwisp state/db/openwisp.dump || true
fi

# Django ops
cd "$APP"
"$APP/venv/bin/python" manage.py migrate --noinput || true
DJANGO_SUPERUSER_USERNAME="$BB_SU" DJANGO_SUPERUSER_EMAIL="$BB_EMAIL" DJANGO_SUPERUSER_PASSWORD="$BB_SP" "$APP/venv/bin/python" manage.py createsuperuser --noinput || true
"$APP/venv/bin/python" manage.py collectstatic --noinput || true

# Gunicorn service
cat > /etc/systemd/system/gunicorn.service <<EOS
[Unit]
Description=Gunicorn for OpenWISP
After=network.target
[Service]
User=www-data
Group=www-data
WorkingDirectory=$APP
Environment=PATH=$APP/venv/bin
ExecStart=$APP/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:8001 openwisp2.wsgi:application
Restart=always
[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable --now gunicorn

# Apache HTTPS reverse-proxy
cat > /etc/apache2/sites-available/openwisp-ssl.conf <<EOV
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
apachectl configtest >/dev/null && systemctl reload apache2 || systemctl restart apache2

# Health checks + banner
HTTP_CODE=$(curl -s -o /dev/null -w %{http_code} "http://${BB_DOMAIN}")
HTTPS_CODE=$(curl -k -s -o /dev/null -w %{http_code} "https://${BB_DOMAIN}")
ADMIN_CODE=$(curl -k -s -o /dev/null -w %{http_code} "https://${BB_DOMAIN}/admin/login/")
GUNI_STATUS=$(systemctl is-active gunicorn >/dev/null 2>&1 && echo active || echo inactive)
echo "HTTP_STATUS=${HTTP_CODE}"
echo "HTTPS_STATUS=${HTTPS_CODE}"
echo "ADMIN_STATUS=${ADMIN_CODE}"
echo "GUNICORN=${GUNI_STATUS}"
echo "Admin: https://${BB_DOMAIN}/admin/"
[ -f /root/babyblue_inventory/openwisp_env.sh ] && echo "API base: https://${BB_DOMAIN}/api/v1/ (Bearer token in /root/babyblue_inventory/openwisp_env.sh)" || true
printf "\033[1;32m%s\033[0m\n" "BlueHub net.isp.vpn"
printf "\033[1;32m%s\033[0m\n" "Done Join & Enjoy"
