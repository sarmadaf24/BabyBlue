#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ===== Vars =====
APP_DIR="${APP_DIR:-/opt/openwisp2}"
REPO_URL="${REPO_URL:-https://github.com/sarmadaf24/BabyBlue.git}"
BRANCH="${BRANCH:-main}"
OLD_DOMAIN="${OLD_DOMAIN:-baby.bluenet.click}"   # دامنه‌ای که باید جایگزین شود
SECRETS_URL="${SECRETS_URL:-}"                   # اختیاری: tar.gz شامل db/media/keys

# اگر DOMAIN ست نیست، از کاربر بپرس
if [ -z "${DOMAIN:-}" ]; then
  read -rp "Enter NEW domain (e.g. example.com): " DOMAIN
fi
if [ -z "${DOMAIN}" ]; then
  echo "ERROR: DOMAIN is empty."; exit 1
fi
EMAIL="${EMAIL:-admin@${DOMAIN}}"

# Django superuser
DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-${EMAIL}}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-ChangeMe!123}"

echo "[0/10] Preseed (no prompts: iptables-persistent, postfix)"
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

echo "[3/10] Release :80 for Apache"
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true
sudo systemctl mask nginx || true
# کشتن هر پروسه روی پورت 80
sudo bash -lc "ss -ltnp | awk '\$4 ~ /:80$/' | awk '{print \$NF}' | sed 's/pid=//;s/,.*//' | xargs -r kill -9" || true
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

echo "[7/10] Domain replace inside project (replace ${OLD_DOMAIN} → ${DOMAIN})"
# فقط فایل‌های متنی معمول
find "${APP_DIR}" -type f \( \
  -name "*.py" -o -name "*.conf" -o -name "*.env" -o -name "*.json" -o \
  -name "*.yml" -o -name "*.yaml" -o -name "*.ini" -o -name "*.txt" -o \
  -name "*.html" -o -name "*.htm" -o -name "*.css" -o -name "*.js" -o \
  -name "*.service" \
\) -print0 | xargs -0 -r sed -i \
  -e "s/${OLD_DOMAIN//\./\\.}/${DOMAIN//\./\\.}/g" \
  -e "s/www\.${OLD_DOMAIN//\./\\.}/www.${DOMAIN//\./\\.}/g"

echo "[8/10] Django migrate/collectstatic + superuser"
# پیدا کردن manage.py
MANAGE_FILE="$(find "${APP_DIR}" -maxdepth 4 -type f -name manage.py | head -n1 || true)"
if [ -z "${MANAGE_FILE}" ]; then
  echo "ERROR: manage.py not found under ${APP_DIR}"; exit 1
fi
DJANGO_DIR="$(dirname "${MANAGE_FILE}")"
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

echo "[9/10] Apache vhost + WSGI (auto-detect)"
# پیدا کردن wsgi.py
WSGI_FILE="${APP_DIR}/config/wsgi.py"
[ -f "${WSGI_FILE}" ] || WSGI_FILE="$(find "${APP_DIR}" -maxdepth 4 -type f -name wsgi.py | head -n1 || true)"
if [ -z "${WSGI_FILE}" ]; then
  echo "ERROR: wsgi.py not found under ${APP_DIR}"; exit 1
fi
STATIC_DIR="${DJANGO_DIR}/static"
MEDIA_DIR="${DJANGO_DIR}/media"

sudo tee "/etc/apache2/sites-available/${DOMAIN}.conf" >/dev/null <<APACHECONF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}

    WSGIDaemonProcess babyblue python-home=${APP_DIR}/venv python-path=${APP_DIR}
    WSGIProcessGroup babyblue
    WSGIScriptAlias / ${WSGI_FILE}

    Alias /static ${STATIC_DIR}
    <Directory ${STATIC_DIR}>
        Require all granted
    </Directory>

    Alias /media ${MEDIA_DIR}
    <Directory ${MEDIA_DIR}>
        Require all granted
    </Directory>

    <Directory "$(dirname "${WSGI_FILE}")">
        <Files wsgi.py>
            Require all granted
        </Files>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
APACHECONF
sudo a2ensite "${DOMAIN}.conf"
sudo a2dissite 000-default.conf || true
sudo apachectl configtest
sudo systemctl restart apache2

echo "[10/10] SSL (Let's Encrypt) + health-check"
sudo certbot --apache -d "${DOMAIN}" -d "www.${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect || true
sleep 2
curl -I --max-time 10 "https://${DOMAIN}/admin/login/" || true

echo "✅ DONE: https://${DOMAIN}"
