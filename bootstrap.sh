#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

APP_DIR="${APP_DIR:-/opt/openwisp2}"
REPO_URL="${REPO_URL:-https://github.com/sarmadaf24/BabyBlue.git}"
BRANCH="${BRANCH:-main}"
OLD_DOMAIN="${OLD_DOMAIN:-baby.bluenet.click}"
SECRETS_URL="${SECRETS_URL:-}"

if [ -z "${DOMAIN:-}" ]; then
  if [ -r /dev/tty ]; then read -rp "Domain: " DOMAIN </dev/tty; fi
fi
[ -n "${DOMAIN:-}" ] || { echo "ERROR: DOMAIN is empty. export DOMAIN=example.com"; exit 1; }
EMAIL="${EMAIL:-admin@${DOMAIN}}"

MANAGE_PATH="${MANAGE_PATH:-}"
WSGI_PATH="${WSGI_PATH:-}"

DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-${EMAIL}}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-ChangeMe!123}"

sudo bash -lc "
  echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
  echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
  echo 'postfix postfix/main_mailer_type select Local only' | debconf-set-selections
  echo 'postfix postfix/mailname string ${DOMAIN}' | debconf-set-selections
"

ARCH=\"$(dpkg --print-architecture || echo amd64)\"
if [ \"${ARCH}\" = \"arm64\" ]; then
  sudo tee /etc/apt/sources.list >/dev/null <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports jammy main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-backports main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports jammy-security main restricted universe multiverse
EOF
fi

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
  qemu-guest-agent tree sshpass build-essential || true

sudo ufw allow OpenSSH
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 51820/udp
sudo ufw allow 1194/udp
sudo ufw --force enable
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ipforward.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-ipforward.conf

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

sudo mkdir -p "${APP_DIR}"
sudo chown "$USER":"$USER" "${APP_DIR}"
if [ ! -d "${APP_DIR}/.git" ]; then
  git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
else
  git -C "${APP_DIR}" fetch origin
  git -C "${APP_DIR}" checkout "${BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
fi

cd "${APP_DIR}"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip wheel
pip install "Django>=4.2,<5" djangorestframework dj-rest-auth django-allauth \
            openwisp-users openwisp-controller openwisp-radius
[ -f requirements.txt ] && pip install -r requirements.txt || true

if [ -n "${SECRETS_URL}" ]; then
  TMP_SECRETS="/tmp/secrets.tar.gz"
  curl -fsSL "${SECRETS_URL}" -o "${TMP_SECRETS}"
  sudo tar -xzf "${TMP_SECRETS}" -C /
  rm -f "${TMP_SECRETS}"
fi

if [ "${DOMAIN}" != "${OLD_DOMAIN}" ]; then
  find "${APP_DIR}" -type f \( -name "*.py" -o -name "*.conf" -o -name "*.env" -o -name "*.json" -o -name "*.yml" -o -name "*.yaml" -o -name "*.ini" -o -name "*.txt" -o -name "*.html" -o -name "*.htm" -o -name "*.css" -o -name "*.js" -o -name "*.service" \) \
  -not -path "*/venv/*" -not -path "*/.git/*" -print0 | xargs -0 -r sed -i \
  -e "s/${OLD_DOMAIN//\./\\.}/${DOMAIN//\./\\.}/g" \
  -e "s/www\.${OLD_DOMAIN//\./\\.}/www.${DOMAIN//\./\\.}/g"
fi

if [ -z "${MANAGE_PATH}" ]; then
  MANAGE_PATH="$(find "${APP_DIR}" -maxdepth 12 -type f -name manage.py -not -path '*/venv/*' -not -path '*/.git/*' | head -n1 || true)"
fi

if [ -z "${MANAGE_PATH}" ]; then
  mkdir -p "${APP_DIR}/app"
  pushd "${APP_DIR}/app" >/dev/null
  django-admin startproject openwisp_proj .
  popd >/dev/null

  SETTINGS="${APP_DIR}/app/openwisp_proj/settings.py"
  WSGI_PATH="${APP_DIR}/app/openwisp_proj/wsgi.py"
  SECRET="$(python - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
  cat > "${SETTINGS}" <<EOF
import os
from pathlib import Path
BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.getenv('DJANGO_SECRET_KEY', '${SECRET}')
DEBUG = False
ALLOWED_HOSTS = ['${DOMAIN}', 'www.${DOMAIN}', '127.0.0.1', 'localhost']

INSTALLED_APPS = [
    'django.contrib.admin','django.contrib.auth','django.contrib.contenttypes',
    'django.contrib.sessions','django.contrib.messages','django.contrib.staticfiles',
    'django.contrib.sites',
    'rest_framework',
    'allauth','allauth.account','allauth.socialaccount',
    'dj_rest_auth',
    'openwisp_users',
    'openwisp_controller',
    'openwisp_radius',
]
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'allauth.account.middleware.AccountMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]
ROOT_URLCONF = 'openwisp_proj.urls'
TEMPLATES = [{
    'BACKEND': 'django.template.backends.django.DjangoTemplates',
    'DIRS': [], 'APP_DIRS': True,
    'OPTIONS': {'context_processors': [
        'django.template.context_processors.debug',
        'django.template.context_processors.request',
        'django.contrib.auth.context_processors.auth',
        'django.contrib.messages.context_processors.messages',
    ]},
}]
WSGI_APPLICATION = 'openwisp_proj.wsgi.application'
DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3','NAME': BASE_DIR / 'db.sqlite3'}}
AUTH_PASSWORD_VALIDATORS = []
LANGUAGE_CODE = 'en-us'; TIME_ZONE = 'UTC'; USE_I18N = True; USE_TZ = True
STATIC_URL = '/static/'; STATIC_ROOT = os.path.join(BASE_DIR,'static')
MEDIA_URL = '/media/'; MEDIA_ROOT = os.path.join(BASE_DIR,'media')
PRIVATE_STORAGE_ROOT = os.path.join(BASE_DIR,'private')
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
SITE_ID = 1
AUTH_USER_MODEL = 'openwisp_users.User'
ACCOUNT_EMAIL_VERIFICATION = 'none'
ACCOUNT_AUTHENTICATION_METHOD = 'username'
ACCOUNT_EMAIL_REQUIRED = False
EOF

  cat > "${APP_DIR}/app/openwisp_proj/urls.py" <<'EOF'
from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static

urlpatterns = [
    path('admin/', admin.site.urls),
    path('accounts/', include('allauth.urls')),
]
urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
EOF

  MANAGE_PATH="${APP_DIR}/app/manage.py"
  if [ ! -f "${MANAGE_PATH}" ]; then
    cat > "${MANAGE_PATH}" <<'EOF'
#!/usr/bin/env python3
import os, sys
if __name__ == "__main__":
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "openwisp_proj.settings")
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
EOF
    chmod +x "${MANAGE_PATH}"
  fi
fi

DJANGO_DIR="$(dirname "${MANAGE_PATH}")"
mkdir -p "${DJANGO_DIR}/static" "${DJANGO_DIR}/media" "${DJANGO_DIR}/private"
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

if [ -z "${WSGI_PATH}" ]; then
  WSGI_PATH="$(find "${APP_DIR}" -maxdepth 12 -type f -name wsgi.py -not -path '*/venv/*' -not -path '*/.git/*' | head -n1 || true)"
fi
[ -n "${WSGI_PATH}" ] && [ -f "${WSGI_PATH}" ] || { echo "ERROR: wsgi.py not found"; exit 1; }
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
    <Directory ${STATIC_DIR}>Require all granted</Directory>
    Alias /media ${MEDIA_DIR}
    <Directory ${MEDIA_DIR}>Require all granted</Directory>
    <Directory "$(dirname "${WSGI_PATH}")"><Files wsgi.py>Require all granted</Files></Directory>
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
APACHECONF
sudo a2ensite "${DOMAIN}.conf"
sudo a2dissite 000-default.conf default-ssl.conf 2>/dev/null || true
sudo apachectl configtest
sudo systemctl restart apache2

DOMS=(-d "${DOMAIN}")
if getent hosts "www.${DOMAIN}" >/dev/null 2>&1; then DOMS+=(-d "www.${DOMAIN}"); fi
sudo certbot --apache "${DOMS[@]}" --non-interactive --agree-tos -m "${EMAIL}" --redirect || true

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

sudo netfilter-persistent save || true

echo "== Ports =="; sudo ss -lunp | grep -E ':(1194|51820|80|443)' || true
echo "== WireGuard =="; sudo wg show || true
echo "== OpenVPN =="; sudo systemctl status openvpn@server --no-pager || true
echo "✅ FULL DONE: https://${DOMAIN}"
