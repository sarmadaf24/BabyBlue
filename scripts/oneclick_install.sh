#!/usr/bin/env bash
set -euo pipefail

read -rp "Domain (e.g. example.com): " BB_DOMAIN
read -rp "Email for SSL: " BB_EMAIL
read -rp "Superuser username [admin]: " BB_SU
read -rsp "Superuser password [admin123]: " BB_SP; echo
BB_SU="${BB_SU:-admin}"
BB_SP="${BB_SP:-admin123}"
[ -z "${BB_EMAIL:-}" ] && BB_EMAIL="admin@${BB_DOMAIN}"

OLD_DOMAIN="$(grep -RhoE "ServerName[[:space:]]+[^[:space:]]+" config/apache/*.conf 2>/dev/null | awk "{print \$2}" | head -n1 || true)"
[ -z "$OLD_DOMAIN" ] && OLD_DOMAIN="blue.nawpa.ir"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apache2 certbot python3-certbot-apache postgresql redis-server python3-venv

# Apache
if ls config/apache/*.conf >/dev/null 2>&1; then
  cp -a config/apache/*.conf /etc/apache2/sites-available/ || true
  sed -i "s/${OLD_DOMAIN//./\\.}/${BB_DOMAIN}/g" /etc/apache2/sites-available/*.conf || true
fi
a2enmod ssl rewrite headers proxy proxy_http >/dev/null 2>&1 || true
if ! grep -R "$BB_DOMAIN" -n /etc/apache2/sites-available/*.conf >/dev/null 2>&1; then
  cat >/etc/apache2/sites-available/openwisp.conf <<EOV
<VirtualHost *:80>
    ServerName ${BB_DOMAIN}
    Redirect permanent / https://${BB_DOMAIN}/
</VirtualHost>
EOV
  a2ensite openwisp.conf >/dev/null 2>&1 || true
else
  for f in /etc/apache2/sites-available/*.conf; do a2ensite "$(basename "$f")" >/dev/null 2>&1 || true; done
fi
systemctl reload apache2 || systemctl restart apache2 || true
certbot --apache -d "$BB_DOMAIN" --non-interactive --agree-tos -m "$BB_EMAIL" || true

# systemd units
if ls config/systemd/*.service >/dev/null 2>&1; then
  cp -a config/systemd/*.service /etc/systemd/system/
fi
if [ -d config/systemd/env ]; then
  install -m 600 -D config/systemd/env/* /etc/default/ || true
fi
systemctl daemon-reload || true
for s in gunicorn.service openwisp.service openwisp*\.service celery*\.service; do
  systemctl enable "$s" >/dev/null 2>&1 || true
  systemctl restart "$s" >/dev/null 2>&1 || true
done

# App files
APP_DIR="/opt/openwisp2"
if [ -f config/app/settings.py ]; then
  install -m 644 -D config/app/settings.py "$APP_DIR/openwisp2/settings.py"
fi
[ -d state/files/static ] && mkdir -p "$APP_DIR/static" && cp -a state/files/static/. "$APP_DIR/static/" || true
[ -d state/files/media ] && mkdir -p "$APP_DIR/media" && cp -a state/files/media/. "$APP_DIR/media/" || true

# OpenWISP inventory env
mkdir -p /root/babyblue_inventory
if [ -f inventory/openwisp_env.sh ]; then
  install -m 600 -D inventory/openwisp_env.sh /root/babyblue_inventory/openwisp_env.sh
  sed -i "s#^OPENWISP_URL=.*#OPENWISP_URL=https://${BB_DOMAIN}#g" /root/babyblue_inventory/openwisp_env.sh || true
fi

# DB restore
if [ -f state/db/openwisp.dump ]; then
  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl start postgresql >/dev/null 2>&1 || true
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname=openwisp;" | grep -q 1 || sudo -u postgres createdb openwisp
  sudo -u postgres pg_restore -j 2 -c -d openwisp state/db/openwisp.dump || true
fi

# Django migrate & superuser
if [ -f "$APP_DIR/manage.py" ]; then
  (cd "$APP_DIR" && python3 manage.py migrate --noinput) || true
  (cd "$APP_DIR" && DJANGO_SUPERUSER_USERNAME="$BB_SU" DJANGO_SUPERUSER_EMAIL="$BB_EMAIL" DJANGO_SUPERUSER_PASSWORD="$BB_SP" python3 manage.py createsuperuser --noinput) || true
  (cd "$APP_DIR" && python3 manage.py collectstatic --noinput) || true
fi

# Health check
curl -I "https://${BB_DOMAIN}/" --max-time 15 || true
echo "==> ONE-CLICK DEPLOY COMPLETE"
