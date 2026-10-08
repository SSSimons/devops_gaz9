#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
docker compose config --quiet
docker compose run --rm --no-deps --entrypoint /bin/promtool prometheus \
  check config /etc/prometheus/prometheus.yml
docker compose run --rm --no-deps --entrypoint /bin/amtool alertmanager \
  check-config /etc/alertmanager/alertmanager.yml
echo "Конфиги Compose, Prometheus и Alertmanager проверены."
