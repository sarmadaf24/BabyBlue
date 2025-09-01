#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ===== Vars =====
APP_DIR="${APP_DIR:-/opt/openwisp2}"
REPO_URL="${REPO_URL:-https://github.com/sarmadaf24/BabyBlue.git}"
BRANCH="${BRANCH:-main}"
OLD_DOMAIN="${OLD_DOMAIN:-baby.bluenet.click}"
SECRETS_URL="${SECRETS_URL:-}"   # optional tar.gz with /opt/openwisp2/db.sqlite3, /opt/openwisp2/media, VPN keys, ...

# Prompt DOMAIN even under curl|bash
if [ -z "${DOMAIN:-}" ]; then
  if [ -r /dev/tty ]; then read -rp "Domain: " DOMAIN </dev/tty; fi
fi
[ -n "${DOMAIN:-}" ] || { echo "ERROR: DOMAIN is empty. export DOMAIN=example.com"; exit 1; }
EMAIL="${EMAIL:-admin@${DOMAIN}}"

# Optional overrides (if Django repo has custom paths)
MANAGE_PATH="${MANAGE_PATH:-}"   # e.g. /opt/openwisp2/src/manage.py
WSGI_PATH="${WSGI_PATH:-}"       # e.g. /opt/openwisp2/config/wsgi.py

DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-${EMAIL}}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-ChangeMe!123}"

echo "[0/12] Preseed (no interactive prompts)"
sudo bash -lc "
  echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
  echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
  echo 'postfix postfix/main_mailer_type select Local only' | debconf-set-selections
  echo 'postfix postfix/mailname string ${DOMAIN}' | debconf-set-selections
"

echo "[1/12] APT install/update"
sudo -E apt-get update
sudo -E apt-get -y upgrade
sudo -E apt-get -o Dpkg::Options::='--force-confnew' -y install \
  python3 python3-venv python3-pip git curl jq \
  apache2 libapache2-mod-wsgi-py3 \
  certbot python3-certbot-apache \
  ufw iptables-persistent netfilter-persistent nftables \
  supervisor redis-server \
  nginx openvpn easy-rsa wireguard \
  freeradius postfix mailutils \
  qemu-guest-agent tree sshpass build-essential \
  influxdb uwsgi uwsgi-plugin-python3 || true

echo "[2/12] UFW + ip_forward"
sudo ufw allow OpenSSH
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 51820/udp
sudo ufw allow 1194/udp
sudo ufw --force enable
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-ipforward.conf

echo "[3/12] Reserve :80/:443 for Apache"
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true
sudo systemctl mask nginx || true
sudo fuser -k 80/tcp 2>/dev/null || true
sudo fuser -k 443/tcp 2>/dev/null || true
sudo a2enmod wsgi headers rewrite ssl >/dev/null 2>&1 || true
echo "ServerName ${DOMAIN}" | sudo tee /etc/apache2/conf-available/servername.conf >/dev/null
sudo a2enconf servername >/dev/null 2>&1 || true
sudo systemctl enable --now apache2
sudo systemctl enable --now supervisor
sudo systemctl enable --now redis-server
(sudo systemctl enable --now ssh || sudo systemctl enable --now sshd) || true

echo "[4/12] Clone/Pull repo → ${APP_DIR}"
sudo mkdir -p "${APP_DIR}"
sudo chown "$USER":"$USER" "${APP_DIR}"
if [ ! -d "${APP_DIR}/.git" ]; then
  git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
else
  git -C "${APP_DIR}" fetch origin
  git -C "${APP_DIR}" checkout "${BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
fi

echo "[5/12] venv + requirements"
cd "${APP_DIR}"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
[ -f requirements.txt ] && pip install -r requirements.txt || true

echo "[6/12] (optional) restore secrets"
if [ -n "${SECRETS_URL}" ]; then
  TMP_SECRETS="/tmp/secrets.tar.gz"
  curl -fsSL "${SECRETS_URL}" -o "${TMP_SECRETS}"
  sudo tar -xzf "${TMP_SECRETS}" -C /
  rm -f "${TMP_SECRETS}"
fi

echo "[7/12] Replace OLD_DOMAIN → DOMAIN (safe)"
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

echo "[8/12] Django steps if available; else static vhost"
# Detect manage.py deeply
if [ -z "${MANAGE_PATH}" ]; then
  MANAGE_PATH="$(find "${APP_DIR}" -maxdepth 12 -type f -name manage.py -not -path '*/venv/*' -not -path '*/.git/*' | head -n1 || true)"
fi
VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
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
  [ -n "${WSGI_PATH}" ] && [ -f "${WSGI_PATH}" ] || { echo "ERROR: wsgi.py not found"; exit 1; }
  STATIC_DIR="${DJANGO_DIR}/static"
  MEDIA_DIR="${DJANGO_DIR}/media"
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
  echo "No manage.py found → static landing vhost."
  DOCROOT="/var/www/${DOMAIN}/html"
  sudo mkdir -p "${DOCROOT}"
  echo "<h1>${DOMAIN}</h1>" | sudo tee "${DOCROOT}/index.html" >/dev/null
  sudo tee "${VHOST_FILE}" >/dev/null <<APACHECONF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${DOCROOT}
    <Directory ${DOCROOT}>
        Require all granted
        Options -Indexes
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
APACHECONF
fi
sudo a2ensite "${DOMAIN}.conf"
sudo a2dissite 000-default.conf default-ssl.conf 2>/dev/null || true
sudo apachectl configtest
sudo systemctl restart apache2

echo "[9/12] SSL (Let's Encrypt) + redirect"
DOMS=(-d "${DOMAIN}")
if getent hosts "www.${DOMAIN}" >/dev/null 2>&1; then DOMS+=(-d "www.${DOMAIN}"); fi
sudo certbot --apache "${DOMS[@]}" --non-interactive --agree-tos -m "${EMAIL}" --redirect || true

echo "[10/12] WireGuard (wg0 10.99.0.1/24, 51820/udp) + NAT"
WAN_IF="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
sudo install -d -m 0700 /etc/wireguard
[ -f /etc/wireguard/server_private.key ] || (umask 077; wg genkey | sudo tee /etc/wireguard/server_private.key >/dev/null)
[ -f /etc/wireguard/server_public.key ]  || (sudo cat /etc/wireguard/server_private.key | wg pubkey | sudo tee /etc/wireguard/server_public.key >/dev/null)
WG_PK="$(sudo cat /etc/wireguard/server_private.key)"
sudo tee /etc/wireguard/wg0.conf >/dev/null <<EOF
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = ${WG_PK}
SaveConfig = true
PostUp = iptables -t nat -C POSTROUTING -s 10.99.0.0/24 -o ${WAN_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.99.0.0/24 -o ${WAN_IF} -j MASQUERADE || true
EOF
sudo systemctl enable --now wg-quick@wg0
sudo iptables -t nat -C POSTROUTING -s 10.99.0.0/24 -o "${WAN_IF}" -j MASQUERADE 2>/dev/null || sudo iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o "${WAN_IF}" -j MASQUERADE

echo "[11/12] OpenVPN (10.99.1.0/24, 1194/udp) + PKI"
export EASYRSA_BATCH=1
if [ ! -f /etc/openvpn/ca.crt ]; then
  sudo rm -rf /etc/openvpn/easy-rsa
  sudo make-cadir /etc/openvpn/easy-rsa
  cd /etc/openvpn/easy-rsa
  sudo ./easyrsa init-pki
  sudo ./easyrsa build-ca nopass
  sudo ./easyrsa gen-dh
  sudo ./easyrsa build-server-full ovpn-main nopass
  sudo openvpn --genkey secret /etc/openvpn/ta.key
  sudo install -m0644 pki/ca.crt                 /etc/openvpn/ca.crt
  sudo install -m0640 pki/private/ovpn-main.key  /etc/openvpn/ovpn-main.key
  sudo install -m0644 pki/issued/ovpn-main.crt   /etc/openvpn/ovpn-main.crt
  sudo install -m0644 pki/dh.pem                 /etc/openvpn/dh.pem
fi
sudo tee /etc/openvpn/server.conf >/dev/null <<'EOF'
port 1194
proto udp
dev ovpn0
server 10.99.1.0 255.255.255.0
topology subnet
client-to-client
keepalive 10 120
persist-key
persist-tun

cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM
data-ciphers-fallback AES-256-GCM
auth SHA256

ca /etc/openvpn/ca.crt
cert /etc/openvpn/ovpn-main.crt
key /etc/openvpn/ovpn-main.key
dh /etc/openvpn/dh.pem
tls-auth /etc/openvpn/ta.key 0
key-direction 0

user nobody
group nogroup
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3
EOF
sudo systemctl enable --now openvpn@server

echo "[12/12] Persist NAT rules"
sudo netfilter-persistent save || true

# Health
echo "== Apache =="
sudo apachectl -S || true
echo "== Ports =="
sudo ss -lunp | grep -E ':(1194|51820|80|443)' || true
echo "== WireGuard =="
sudo wg show || true
echo "== OpenVPN =="
sudo systemctl status openvpn@server --no-pager || true

echo "✅ FULL DONE: https://${DOMAIN}"
