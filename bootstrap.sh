#!/usr/bin/env bash
set -euo pipefail
apt -y update
apt -y install python3 python3-pip git ansible
ansible-galaxy collection install community.general
ansible-pull \
  -U https://github.com/sarmadaf24/BabyBlue.git \
  -C main \
  -d /opt/ansible-pull/BabyBlue \
  -i localhost, \
  -e ansible_python_interpreter=/usr/bin/python3 \
  site.yml
