#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ===== Vars =====
APP_DIR="${APP_DIR:-/opt/openwisp2}"
REPO_URL="${REPO_URL:-https://github.com/sarmadaf24/BabyBlue.git}"
BRANCH="${BRANCH:-main}"
OLD_DOMAIN="${OLD_DOMAIN:-baby.bluenet.click}"
SECRETS_URL="${SECRETS_URL:-}"

# Prompt domain even under curl|bash
if [ -z "${DOMAIN:-}" ]; then
  if [ -r /dev/tty ]; then
    read -rp "Enter NEW domain (e.g. example.com): " DOMAIN </dev/tty
  fi
fi
if [ -z "${DOMAIN:-}" ]; then
  echo "ERROR: DOMAIN is empty. export DOMAIN=example.com then rerun."; exit 1
fi
EMAIL="${EMAIL:-admin@${DOMAIN}}"

# Optional overrides if Django exists elsewhere
MANAGE_PATH="${MANAGE_PATH:-}"   # e.g. /opt/openwisp2/src/manage.py
WSGI_PATH="${WSGI_PATH:-}"       # e.g. /opt/openwisp2/config/wsgi.py

DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-${EMAIL}}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-ChangeMe!123}"

echo "[0/10] Preseed (no interactive prompts)"
sudo bash -lc "
  echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
  echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
  echo 'postfix postfix/main_mailer_type select Local only' | debconf-set-selections
  echo 'postfix postfix/mailname string ${DOMAIN}' | debconf-set-selections
"

echo "[1/10] APT install/update"
sudo -E apt-get update
sudo -E apt-get -y upgrade
sudo -E apt-get -o Dpkg::Options::='--force-confnew' -y install \
  python3 python3-venv python3-pip git curl jq \
  apache2 libapache2-mod-wsgi-py3 \
  certbot python3-certbot-apache \
  ufw iptables-persistent netfilter-persistent nftables \
  supervisor redis-server \
  nginx openvpn easy-rsa wireguard freeradius \
  postfix mailutils \
  qemu-guest-agent tree sshpass build-essential \
  influxdb || true

echo "[2/10] UFW + ip_forward"
sudo ufw allow OpenSSH
sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-ipforward.conf

echo "[3/10] Free port 80 for Apache (no races)"
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true
sudo systemctl mask nginx || true
sudo fuser -k 80/tcp || true
sudo a2enmod wsgi headers rewrite
sudo systemctl enable --now apache2
sudo systemctl enable --now supervisor
sudo systemctl enable --now redis-server
(sudo systemctl enable --now ssh || sudo systemctl enable --now sshd) || true

echo "[4/10] Clone/Pull repo → ${APP_DIR}"
sudo mkdir -p "${APP_DIR}"
sudo chown "$USER":"$USER" "${APP_DIR}"
if [ ! -d "${APP_DIR}/.git" ]; then
  git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
else
  git -C "${APP_DIR}" fetch origin
  git -C "${APP_DIR}" checkout "${BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
fi

echo "[5/10] venv + requirements"
cd "${APP_DIR}"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
[ -f requirements.txt ] && pip install -r requirements.txt || true

echo "[6/10] (optional) restore secrets"
if [ -n "${SECRETS_URL}" ]; then
  TMP_SECRETS="/tmp/secrets.tar.gz"
  curl -fsSL "${SECRETS_URL}" -o "${TMP_SECRETS}"
  sudo tar -xzf "${TMP_SECRETS}" -C /
  rm -f "${TMP_SECRETS}"
fi

echo "[7/10] Replace OLD_DOMAIN → DOMAIN in text files (safe)"
if [ "${DOMAIN}" != "${OLD_DOMAIN}" ]; then
  find "${APP_DIR}" -type f \( \
    -name "*.py" -o -name "*.conf" -o -name "*.env" -o -name "*.json" -o \
    -name "*.yml" -o -name "*.yaml" -o -name "*.ini" -o -name "*.txt" -o \
    -name "*.html" -o -name "*.htm" -o -name "*.css" -o -name "*.js" -o \
    -name "*.service" \
  \) -not -path "*/venv/*" -not -path "*/.git/*" -print0 | xargs -0 -r sed -i \
    -e "s/${OLD_DOMAIN//\./\\.}/${DOMAIN//\./\\.}/g" \
    -e "s/www\.${OLD_DOMAIN//\./\\.}/www.${DOMAIN//\./\\.}/g"
else
  echo "Skip replace (DOMAIN == OLD_DOMAIN)"
fi

echo "[8/10] Django steps (auto-skip if manage.py not found)"
if [ -z "${MANAGE_PATH}" ]; then
  MANAGE_PATH="$(find "${APP_DIR}" -maxdepth 12 -type f -name manage.py -not -path '*/venv/*' -not -path '*/.git/*' | head -n1 || true)"
fi
if [ -n "${MANAGE_PATH}" ] && [ -f "${MANAGE_PATH}" ]; then
  DJANGO_DIR="$(dirname "${MANAGE_PATH}")"
  echo "MANAGE_PATH=${MANAGE_PATH}"
  echo "DJANGO_DIR=${DJANGO_DIR}"
  source "${APP_DIR}/venv/bin/activate"
  cd "${DJANGO_DIR}"
  python manage.py migrate --noinput
  python manage.py collectstatic --noinput
  export DJANGO_SUPERUSER_USERNAME DJANGO_SUPERUSER_EMAIL DJANGO_SUPERUSER_PASSWORD
  python manage.py shell <<'PYCODE'
from django.contrib.auth import get_user_model
import os
User = get_user_model()
u, created = User.objects.get_or_create(
    username=os.environ["DJANGO_SUPERUSER_USERNAME"],
    defaults={"email": os.environ["DJANGO_SUPERUSER_EMAIL"], "is_staff": True, "is_superuser": True},
)
if created:
    u.set_password(os.environ["DJANGO_SUPERUSER_PASSWORD"]); u.save()
PYCODE
  # Detect WSGI
  if [ -z "${WSGI_PATH}" ]; then
    WSGI_PATH="${APP_DIR}/config/wsgi.py"
    [ -f "${WSGI_PATH}" ] || WSGI_PATH="$(find "${APP_DIR}" -maxdepth 12 -type f -name wsgi.py -not -path '*/venv/*' -not -path '*/.git/*' | head -n1 || true)"
  fi
  if [ -z "${WSGI_PATH}" ] || [ ! -f "${WSGI_PATH}" ]; then
    echo "ERROR: wsgi.py not found; cannot configure WSGI vhost."; exit 1
  fi
  STATIC_DIR="${DJANGO_DIR}/static"
  MEDIA_DIR="${DJANGO_DIR}/media"
  VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
  sudo tee "${VHOST_FILE}" >/dev/null <<APACHECONF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}

    WSGIDaemonProcess babyblue python-home=${APP_DIR}/venv python-path=${APP_DIR}
    WSGIProcessGroup babyblue
    WSGIScriptAlias / ${WSGI_PATH}

    Alias /static ${STATIC_DIR}
    <Directory ${STATIC_DIR}>
        Require all granted
    </Directory>

    Alias /media ${MEDIA_DIR}
    <Directory ${MEDIA_DIR}>
        Require all granted
    </Directory>

    <Directory "$(dirname "${WSGI_PATH}")">
        <Files wsgi.py>
            Require all granted
        </Files>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
APACHECONF
else
  echo "No manage.py found → configuring static landing vhost."
  VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
  sudo mkdir -p "/var/www/${DOMAIN}/html"
  echo "<h1>OK: ${DOMAIN}</h1>" | sudo tee "/var/www/${DOMAIN}/html/index.html" >/dev/null
  sudo tee "${VHOST_FILE}" >/dev/null <<APACHECONF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot /var/www/${DOMAIN}/html
    <Directory /var/www/${DOMAIN}/html>
        Require all granted
        Options -Indexes
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
APACHECONF
fi

echo "[9/10] Enable vhost + restart Apache"
sudo a2ensite "${DOMAIN}.conf"
sudo a2dissite 000-default.conf || true
sudo apachectl configtest
sudo systemctl restart apache2

echo "[10/10] SSL (Let's Encrypt) + health-check"
sudo certbot --apache -d "${DOMAIN}" -d "www.${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect || true
sleep 2
curl -I --max-time 10 "https://${DOMAIN}/" || true
curl -I --max-time 10 "https://${DOMAIN}/admin/login/" || true

echo "✅ DONE: https://${DOMAIN}"
