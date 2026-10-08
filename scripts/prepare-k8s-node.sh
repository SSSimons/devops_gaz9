#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт через sudo." >&2
  exit 1
fi
. /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 22.04 ]]; then
  echo "Скрипт рассчитан на чистую Ubuntu Server 22.04." >&2
  exit 1
fi
# На всех трёх нодах используем одну версию Kubernetes.
K8S_MINOR="v1.36"
if command -v docker >/dev/null; then
  echo "Для ноды нужна отдельная VM без Docker Engine." >&2
  exit 1
fi
# Отключаем swap сейчас и после перезагрузки.
swapoff -a
if [[ ! -f /etc/fstab.service-lab.backup ]]; then
  cp -a /etc/fstab /etc/fstab.service-lab.backup
fi
python3 - <<'PY'
from pathlib import Path
fstab = Path("/etc/fstab")
lines = []
for line in fstab.read_text().splitlines():
    fields = line.split()
    if fields and not fields[0].startswith("#") and len(fields) >= 3 and fields[2] == "swap":
        line = "# swap отключён для Kubernetes: " + line
    lines.append(line)
fstab.write_text("\n".join(lines) + "\n")
PY
cat >/etc/modules-load.d/service-lab.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-service-lab-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system
apt-get update
apt-get install -y ca-certificates curl gpg containerd conntrack socat iputils-ping
containerd_version="$(containerd --version | awk '{print $3}' | sed 's/^v//')"
if ! dpkg --compare-versions "$containerd_version" ge 1.7; then
  echo "Обнови Ubuntu через jammy-updates: нужен containerd версии 1.7 или выше." >&2
  exit 1
fi
install -d -m 0755 /etc/containerd /etc/apt/keyrings
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update
# Точную версию пакетов можно передать через K8S_PACKAGE_VERSION.
if [[ -n "${K8S_PACKAGE_VERSION:-}" ]]; then
  apt-get install -y "kubelet=$K8S_PACKAGE_VERSION" "kubeadm=$K8S_PACKAGE_VERSION" "kubectl=$K8S_PACKAGE_VERSION"
else
  apt-get install -y kubelet kubeadm kubectl
fi
apt-mark hold kubelet kubeadm kubectl
kubernetes_version="$(kubeadm version -o short)"
pause_image="$(kubeadm config images list --kubernetes-version "$kubernetes_version" | awk '/\/pause:/ {print; exit}')"
if [[ -z "$pause_image" ]]; then
  echo "Не удалось определить образ pause." >&2
  exit 1
fi
# Указываем образ pause для установленной версии Kubernetes.
sed -i "s#sandbox_image = .*#sandbox_image = \"$pause_image\"#" /etc/containerd/config.toml
systemctl enable --now containerd kubelet
systemctl restart containerd
if [[ ! -x /opt/cni/bin/loopback ]]; then
  echo "Не найден /opt/cni/bin/loopback. Проверь установку CNI." >&2
  exit 1
fi
echo "Нода $(hostname) подготовлена. До kubeadm init/join kubelet может перезапускаться."
echo "Версия Kubernetes: $kubernetes_version"
