#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Запусти: sudo bash scripts/install-systemd.sh" >&2
  exit 1
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
apt-get update
apt-get install -y python3 python3-venv iputils-ping
if ! getent passwd labapp >/dev/null; then
  useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin labapp
fi
if [[ "$(id -u labapp)" -eq 0 ]] || [[ "$(getent passwd labapp | cut -d: -f7)" != "/usr/sbin/nologin" ]]; then
  echo "Проверь пользователя labapp: нужен отдельный аккаунт без входа в систему." >&2
  exit 1
fi
if systemctl is-active --quiet service-lab.service; then
  systemctl stop service-lab.service
fi
install -d -m 0755 /opt/service-lab /opt/service-lab/app
install -m 0644 "$project_dir/requirements.txt" /opt/service-lab/requirements.txt
install -m 0644 "$project_dir/app/main.py" "$project_dir/app/__init__.py" /opt/service-lab/app/
python3 -m venv /opt/service-lab/.venv
/opt/service-lab/.venv/bin/pip install -r /opt/service-lab/requirements.txt
chown -R root:root /opt/service-lab
chmod -R a+rX /opt/service-lab
install -m 0644 "$project_dir/systemd/service-lab.service" /etc/systemd/system/service-lab.service
systemctl daemon-reload
systemctl enable --now service-lab.service
systemctl --no-pager status service-lab.service
