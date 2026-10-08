#!/usr/bin/env bash
set -euo pipefail

# Запускаем от пользователя, которому создали ~/.kube/config после kubeadm init.
if ! command -v helm >/dev/null; then
  echo "Сначала установи Helm, команды есть в README." >&2
  exit 1
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update
helm upgrade --install traefik traefik/traefik \
  --version 41.4.0 --namespace traefik --create-namespace \
  --values "$project_dir/k8s/traefik-values.yaml" \
  --wait --timeout 5m
kubectl -n traefik get pods,svc
