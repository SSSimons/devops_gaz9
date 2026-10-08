# 🛠️ Service Lab - Python, systemd, NAT и Kubernetes

Готовый проект для выполнения пунктов a–h на **VMware Workstation Pro**.
Все виртуальные машины - **Ubuntu Server 22.04 LTS, amd64**.

Проект не создаёт виртуальные машины сам: их нужно создать в VMware.
Сначала выполняй этапы по порядку, проверяя результат каждого. Команды внутри VM
выполняются в Ubuntu, команды `curl.exe` - в PowerShell Windows.

## 1. Что получится

| VM | Назначение | Финальный адрес | Адаптеры VMware | CPU / RAM / диск |
| --- | --- | --- | --- | --- |
| app-vm | Python через systemd; Docker Compose и мониторинг | 192.168.76.10 | VMnet1 | 2 / 2 ГБ / 20 ГБ |
| gateway-vm | NAT-шлюз | LAN: 192.168.76.254; WAN: DHCP | VMnet8 + VMnet1 | 1 / 1 ГБ / 10 ГБ |
| k8s-cp | Control plane Kubernetes | 192.168.76.20 | VMnet1 | 2 / 3 ГБ / 25 ГБ |
| k8s-w1 | Worker | 192.168.76.21 | VMnet1 | 2 / 2 ГБ / 25 ГБ |
| k8s-w2 | Worker | 192.168.76.22 | VMnet1 | 2 / 2 ГБ / 25 ГБ |

Итого **5 VM**: 1 приложение + 1 шлюз + 3 ноды.
Виртуальным машинам выделяется около 10 ГБ RAM. Для одновременного запуска
с Windows желательно 24–32 ГБ; на 16 ГБ следи за свободной памятью.
Перед этапом Kubernetes можно остановить systemd-приложение и контейнер приложения,
оставив мониторинг по необходимости.

Сети:
- **VMnet8 - NAT VMware**: внешний интерфейс gateway-vm получает адрес по DHCP.
- **VMnet1 - Host-only, 192.168.76.0/24**: внутренняя сеть, DHCP выключен.
- Windows-хост в VMnet1: **192.168.76.1/24**, без default gateway.
- Default gateway всех внутренних Ubuntu: **192.168.76.254**.

Трафик наружу: внутренняя VM → gateway-vm → NAT VMware → интернет.
Это двойной NAT. NAT на Ubuntu-шлюзе нужен отдельно и не заменяется NAT VMware.

В пункте e задания перепутана «первая» VM: шлюзом считаем именно Ubuntu с
двумя интерфейсами из пункта d, а VM приложения переносим во внутреннюю сеть.

## 2. Настрой VMware и создай app-vm

1. Скачай **Server install image**:
   https://releases.ubuntu.com/22.04/
2. VMware: **Edit → Virtual Network Editor → Change Settings**.
3. Для VMnet1 выбери **Host-only**, subnet `192.168.76.0`, mask `255.255.255.0`.
   Включи **Connect a host virtual adapter to this network**.
   Выключи **Use local DHCP service to distribute IP addresses to VMs**.
4. VMnet8 оставь в режиме NAT с включённым DHCP.
   Её подсеть должна отличаться от VMnet1, Pod-сети `10.244.0.0/16`,
   Service-сети `10.96.0.0/12`, VPN и домашней сети.
5. В Windows проверь через `ipconfig`, что адаптер VMware Network Adapter VMnet1
   имеет `192.168.76.1/24`. При необходимости задай адрес в свойствах IPv4;
   default gateway для этого адаптера оставь пустым.
6. Создай app-vm: **File → New Virtual Machine → Typical**.
   ISO Ubuntu 22.04, обычный пользователь `lab`, установка OpenSSH Server.
   **Сначала подключи единственный адаптер к NAT / VMnet8.**
7. В Ubuntu:

```bash
sudo hostnamectl set-hostname app-vm
sudo apt update
sudo apt install -y openssh-server unzip curl
ip -br address
ip route
```

Запиши текущий DHCP-адрес app-vm. Скопируй архив с Windows в Ubuntu.
Замени `<IP_APP>` реальным адресом и используй реальный путь к архиву:

```powershell
scp .\service-lab.zip lab@<IP_APP>:~
```

В Ubuntu:

```bash
cd ~
unzip service-lab.zip
cd ~/service-lab
```

Можно хранить проект в отдельном Git-репозитории, например `service_tz`.
Не обязательно смешивать его с предыдущим Jenkins-проектом `ci_tz`.
При переносе на другие VM копируй всю папку или клонируй этот новый репозиторий.

## 3. Приложение: пункт a

Выбран FastAPI. Точка входа - `app/main.py`.

| Запрос | Результат |
| --- | --- |
| POST / с Test: Hello | 200, текст Hello, World! |
| POST / без Test или с другим значением | 403, текст Forbidden |
| GET / | 405: endpoint принимает POST |
| GET /health, ping 77.88.8.8 успешен | 200, текст OK |
| GET /health, ping неуспешен или не запускается | 503, текст Service Unavailable |
| GET /metrics | Метрики Prometheus |

Имена HTTP-заголовков нечувствительны к регистру; значение `Hello` проверяется точно.
При обращении к /health запускается настоящий `/usr/bin/ping -n -c 1 -W 2 77.88.8.8`.
Нет shell, нет пользовательского адреса в команде; общий таймаут процесса - 3 секунды.
При таймауте или отмене запроса дочерний процесс завершается и освобождается.

Локальный запуск для разработки:

```bash
sudo apt install -y python3-venv iputils-ping
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m app.main
```

В другом терминале:

```bash
curl -i -X POST http://127.0.0.1:8000/ -H 'Test: Hello'
curl -i -X POST http://127.0.0.1:8000/
curl -i http://127.0.0.1:8000/health
```

Перед systemd останови ручной запуск через Ctrl+C.

## 4. systemd под отдельным пользователем: пункт b

**На app-vm**, из папки проекта:

```bash
cd ~/service-lab
sudo bash scripts/install-systemd.sh
```

Скрипт создаёт системного пользователя `labapp` без shell и домашней директории,
копирует приложение в `/opt/service-lab`, создаёт venv и включает
`service-lab.service`. Код принадлежит root, сервис читает его от labapp.

Проверки:

```bash
sudo systemctl status service-lab --no-pager
sudo systemctl show service-lab -p User -p Group -p MainPID -p ActiveState
ps -eo user,pid,args | grep '[u]vicorn'
getent passwd labapp
sudo journalctl -u service-lab -n 50 --no-pager

curl -i -X POST http://127.0.0.1:8000/ -H 'Test: Hello'
curl -i -X POST http://127.0.0.1:8000/ -H 'Test: wrong'
curl -i http://127.0.0.1:8000/health
```

С Windows: `curl.exe -i -X POST http://<IP_APP>:8000/ -H "Test: Hello"`.
Сервис запускается при перезагрузке. Для ICMP ему выдан только `CAP_NET_RAW`,
а сам Python не работает от root.

Управление:

```bash
sudo systemctl restart service-lab
sudo journalctl -u service-lab -f
```

## 5. Docker и мониторинг: пункты c–d

**Только на app-vm**, на свежей Ubuntu без ранее настроенного Docker:

```bash
cd ~/service-lab
sudo bash scripts/install-docker.sh

# Отдельная сборка образа - доказательство пункта c
sudo docker build -t service-lab:1.0.0 .

# Проверка конфигураций выполняется уже на твоей VM
sudo bash scripts/verify-configs.sh

# Приложение + Prometheus + Alertmanager + Blackbox Exporter
sudo docker compose up -d --build
sudo docker compose ps
sudo docker compose logs --tail=50 app

curl -i -X POST http://127.0.0.1:8080/ -H 'Test: Hello'
curl -i http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/metrics
```

systemd использует **8000**, Docker - **8080** на VM, поэтому порты не конфликтуют.
Внутри контейнера приложение слушает 8000.
Образ работает от UID 10001; для ping оставлен только NET_RAW.
В Compose и Pod дополнительно разрешены ICMP echo sockets для GID 10001
через net.ipv4.ping_group_range; Python не требуется запускать от root.

В Windows открой, подставив текущий IP app-vm:
- `http://<IP_APP>:8080/health` - проверка приложения;
- `http://<IP_APP>:9090/targets` - цели Prometheus;
- `http://<IP_APP>:9090/alerts` - правила и состояния;
- `http://<IP_APP>:9093` - Alertmanager.

### Как устроен мониторинг

Prometheus собирает /metrics. Отдельно Blackbox Exporter вызывает /health каждые
15 секунд: проверяет **HTTP 200 и тело OK**. Поэтому ping проверяется регулярно,
даже если никто вручную не открывает endpoint.

Правила:
- AppUnavailable: приложение недоступно по /metrics больше минуты.
- AppHealthFailed: /health не проходит проверку больше минуты.
- HealthProbeUnavailable: недоступен сам Blackbox Exporter.
- AlertmanagerUnavailable: недоступен Alertmanager; проверяется в Prometheus.

Для неработающего ping /metrics остаётся доступным. Такое состояние обнаруживает
именно AppHealthFailed, а не проверка наличия процесса.

Alertmanager принимает и группирует алерты, показывает их в UI.
**Email/Telegram не подключены**: для этого нужны реальные адреса/секреты,
которые можно добавить в `monitoring/alertmanager.yml`.

Проверка отказа приложения:

```bash
sudo docker compose stop app
```

Подожди примерно **1–2 минуты**. Проверь Firing в Prometheus и алерты в Alertmanager.
Затем восстанови:

```bash
sudo docker compose start app
```

Проверка отказа только ICMP: позже временно отключи WAN-адаптер gateway-vm в VMware,
оставив VMnet1 включённой. /metrics будет доступен, /health вернёт 503,
а AppHealthFailed сработает. После проверки подключи WAN обратно.
Не отключай шлюз во время скачивания пакетов или создания кластера.

Prometheus и Alertmanager доступны в учебной сети без авторизации.
Не публикуй их порты на публичный IP.

## 6. NAT-шлюз: пункт d

Создай **gateway-vm** с двумя адаптерами:
- Network Adapter 1 → **Custom: VMnet8**, WAN;
- Network Adapter 2 → **Custom: VMnet1**, LAN.

На обоих включи Connected и Connect at power on.
Установи Ubuntu с OpenSSH и именем gateway-vm; скопируй проект с app-vm,
пока обе VM доступны через VMnet8:

```bash
# На app-vm: замени <IP_GATEWAY_WAN>
scp -r ~/service-lab lab@<IP_GATEWAY_WAN>:~
```

На gateway-vm:

```bash
sudo hostnamectl set-hostname gateway-vm
sudo apt update
sudo apt install -y nftables curl iputils-ping
ip -br address
ip route
```

**Проверь реальные имена интерфейсов.** Обычно WAN - ens33, LAN - ens37, но это
не гарантия. MAC можно сопоставить с VMware → Settings → адаптер → Advanced.
Замени имена в `network/gateway.yaml` и `network/nftables.conf`, если отличаются.

Netplan объединяет все YAML в /etc/netplan. Не оставляй одновременно старый DHCP
и новый static для одного интерфейса. Через **консоль VMware** перенеси прежние
конфиги в отдельную резервную папку:

```bash
cd ~/service-lab
sudo mkdir -p /root/netplan-before-service-lab
sudo bash -c 'for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do [ ! -f "$f" ] || mv "$f" /root/netplan-before-service-lab/; done'
sudo install -m 600 network/gateway.yaml /etc/netplan/01-lab.yaml
# Если установлен cloud-init, запрети ему снова создать DHCP-конфиг
if [ -d /etc/cloud/cloud.cfg.d ]; then
  echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
fi
sudo netplan generate
sudo netplan try
```

В консоли подтверди настройку, только если видны:
WAN - DHCP-адрес и default route через VMnet8; LAN - 192.168.76.254/24.

Включи маршрутизацию и NAT. Файл nftables заменяет правила **только на этой
выделенной свежей VM-шлюзе**; Docker на ней устанавливать не нужно.

```bash
sudo nft list ruleset | sudo tee /root/nftables-before-service-lab.conf >/dev/null
sudo install -m 644 network/99-lab-router.conf /etc/sysctl.d/99-lab-router.conf
sudo sysctl --system
sudo nft -c -f network/nftables.conf
sudo install -m 644 network/nftables.conf /etc/nftables.conf
sudo systemctl enable --now nftables
sudo systemctl restart nftables

sysctl net.ipv4.ip_forward
sudo nft list ruleset
ip -br address
ip route
ping -c 2 77.88.8.8
```

WAN получает default route от VMware DHCP. На LAN default route не добавляется.

## 7. Перенеси app-vm во внутреннюю сеть: пункт e

1. Выключи app-vm.
2. VMware → Settings → Network Adapter → **Custom: VMnet1**.
3. У app-vm остаётся **только один** сетевой интерфейс; дополнительный VMnet8
   не оставляй, иначе выход может обойти Ubuntu-шлюз.
4. Включи app-vm; работай через консоль VMware.
5. Проверь имя интерфейса и исправь `network/internal-node.yaml`.
6. Сохрани старые конфиги и установи новый:

```bash
cd ~/service-lab
ip -br address
sudo mkdir -p /root/netplan-before-service-lab
sudo bash -c 'for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do [ ! -f "$f" ] || mv "$f" /root/netplan-before-service-lab/; done'
sudo install -m 600 network/internal-node.yaml /etc/netplan/01-lab.yaml
if [ -d /etc/cloud/cloud.cfg.d ]; then
  echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
fi
sudo netplan generate
sudo netplan try
```

Теперь проверь:

```bash
ip -br address
ip route
ip route get 77.88.8.8
ping -c 2 192.168.76.254
ping -c 2 77.88.8.8
getent hosts registry.k8s.io
curl -I https://registry.k8s.io
curl -i http://127.0.0.1:8000/health
curl -i http://127.0.0.1:8080/health
```

Маршрут к 77.88.8.8 должен идти **via 192.168.76.254**, адрес VM - 192.168.76.10.
С Windows подключайся `ssh lab@192.168.76.10`.
UI мониторинга теперь по `http://192.168.76.10:9090` и `:9093`.

Если ping до шлюза работает, наружу - нет: проверь WAN, ip_forward и nftables.
Если HTTPS работает, но 77.88.8.8 не отвечает ICMP, /health по ТЗ должен вернуть
503; это не повод подменять ping проверкой HTTPS.

## 8. Три ноды Kubernetes: пункт f

Создай **k8s-cp, k8s-w1, k8s-w2** на Ubuntu 22.04.
У каждой ровно один адаптер: **Custom VMnet1**.
Свежие установки должны иметь разные hostname, MAC и product UUID.
Не клонируй ноду после kubeadm init/join.

Для установки ОС в VMnet1 можно вручную указать:
subnet `192.168.76.0/24`, address своего узла, gateway `192.168.76.254`,
DNS `77.88.8.8,1.1.1.1`.
Либо после установки настрой Netplan через консоль по шаблону internal-node.yaml.

Адреса:
- k8s-cp: 192.168.76.20/24;
- k8s-w1: 192.168.76.21/24;
- k8s-w2: 192.168.76.22/24.

На каждом узле установи свой hostname, например:

```bash
# Только на control plane; на workers поставь k8s-w1 / k8s-w2
sudo hostnamectl set-hostname k8s-cp
```

На **app-vm** скопируй проект на все три ноды:

```bash
for task_ip in 192.168.76.20 192.168.76.21 192.168.76.22; do
  scp -r ~/service-lab "lab@$task_ip:~"
done
```

До подготовки на каждой ноде проверь сеть, отсутствие активного firewall,
который блокирует учебную LAN, и актуальность времени:

```bash
ip route
ping -c 2 192.168.76.254
ping -c 2 77.88.8.8
curl -I https://registry.k8s.io
timedatectl
sudo ufw status
```

Инструкция рассчитана на свежие VM с UFW inactive. Если он активен, сначала
настрой межнодовый доступ по требованиям kubeadm и UDP 8472 для Flannel,
иначе ноды/Pod-сеть не заработают.

### Подготовка: на ВСЕХ трёх нодах

```bash
cd ~/service-lab
sudo bash scripts/prepare-k8s-node.sh
containerd --version
kubeadm version -o short
swapon --show
ls /opt/cni/bin/loopback
```

Скрипт отключает swap в /etc/fstab, включает bridge netfilter/IP forwarding,
ставит containerd, настраивает systemd cgroup и устанавливает kubeadm/kubelet/kubectl
из репозитория **v1.36**. На свежей Ubuntu 22.04 используются containerd 1.x и config v2.
На этих нодах Docker Engine не нужен.

Все три ноды должны получить одинаковую версию пакетов. Если устанавливаешь
их в разные дни, посмотри `apt-cache madison kubeadm` и передай точную доступную
версию одинаково на всех нодах:

```bash
sudo env K8S_PACKAGE_VERSION='<ВЕРСИЯ_ИЗ_APT_CACHE>' bash scripts/prepare-k8s-node.sh
```

Kubelet до init/join может перезапускаться - пока конфигурации кластера нет.

### Инициализация: ТОЛЬКО на k8s-cp

```bash
sudo kubeadm init \
  --kubernetes-version="$(kubeadm version -o short)" \
  --apiserver-advertise-address=192.168.76.20 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --cri-socket=unix:///run/containerd/containerd.sock

mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
```

Сохрани напечатанную `kubeadm join ...` - она нужна двум workers.
Установи Flannel на control plane:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.9/kube-flannel.yml
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s
```

Flannel использует тот же Pod CIDR 10.244.0.0/16.
До установки CNI нода может быть NotReady - это ожидаемо.

### Подключение: на k8s-w1 И k8s-w2

Выполни реальную команду join из вывода init **с sudo**.
Если потерял её, на k8s-cp:

```bash
sudo kubeadm token create --print-join-command
```

На workers результат выглядит так, но токен и хэш бери свои:

```bash
sudo kubeadm join 192.168.76.20:6443 \
  --token <РЕАЛЬНЫЙ_ТОКЕН> \
  --discovery-token-ca-cert-hash sha256:<РЕАЛЬНЫЙ_ХЭШ> \
  --cri-socket=unix:///run/containerd/containerd.sock
```

На k8s-cp:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl wait --for=condition=Ready nodes --all --timeout=300s
```

Должны быть **3 Ready-ноды**. На workers поле ROLES может быть <none> - это нормально.
Это кластер с одним control plane и двумя workers, не HA control plane.

## 9. Загрузить образ и развернуть приложение: пункт g

Образ из локального Docker app-vm **не появляется автоматически** на Kubernetes-нодах.
В стенде используется передача образа через tar; внешний registry не нужен.

На **app-vm**:

```bash
cd ~/service-lab
sudo docker build -t service-lab:1.0.0 .
sudo docker save -o /tmp/service-lab-1.0.0.tar service-lab:1.0.0
sudo chown "$(id -u):$(id -g)" /tmp/service-lab-1.0.0.tar

for task_ip in 192.168.76.20 192.168.76.21 192.168.76.22; do
  scp /tmp/service-lab-1.0.0.tar "lab@$task_ip:/tmp/"
done
```

На **КАЖДОЙ из трёх Kubernetes-нод**:

```bash
sudo ctr --namespace k8s.io images import /tmp/service-lab-1.0.0.tar
sudo ctr --namespace k8s.io images ls | grep service-lab
```

Namespace containerd должен быть именно **k8s.io**.
Manifest использует `imagePullPolicy: Never`: tag должен существовать локально
на любой ноде, куда может попасть Pod.

На **k8s-cp**:

```bash
cd ~/service-lab
kubectl apply -f k8s/app.yaml
kubectl -n service-lab rollout status deployment/service-lab --timeout=180s
kubectl -n service-lab get pods,svc,ingress -o wide
```

Ingress уже создан этим файлом, но до установки контроллера он ещё не обслуживает трафик.
Запускаются 2 реплики приложения. Readiness проверяет /metrics, liveness - TCP:
потеря внешнего ICMP не должна бесконечно перезапускать рабочий процесс.

## 10. Ingress без port-forward: пункт h

На **k8s-cp** установи Helm из официального installer script.
Сначала скачай и прочитай его:

```bash
curl -fsSL -o /tmp/get-helm-4 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
less /tmp/get-helm-4
bash /tmp/get-helm-4
helm version
```

Затем от пользователя `lab`, у которого уже есть ~/.kube/config:

```bash
cd ~/service-lab
bash scripts/install-traefik.sh

kubectl -n traefik get svc
kubectl get ingressclass
kubectl -n service-lab get ingress
```

В Traefik Service должны быть **NodePort 30080**, ingressClass - traefik.
Kubernetes Service публикует ingress-контроллер, а сам ресурс Ingress
направляет запросы с Host: app.lab в ClusterIP Service приложения.

С **Windows PowerShell**:

```powershell
curl.exe -i -X POST http://192.168.76.21:30080/ -H "Host: app.lab" -H "Test: Hello"
curl.exe -i -X POST http://192.168.76.21:30080/ -H "Host: app.lab"
curl.exe -i http://192.168.76.21:30080/health -H "Host: app.lab"
```

Ожидается: 200 Hello, World!; 403 Forbidden; при успешном ping - 200 OK.
Это доступ **с хоста вне Kubernetes через реальный порт ноды**, без port-forward.
Обычный NodePort использует iptables/nftables правила: отсутствие процесса
на 30080 в `ss -lnt` само по себе не доказывает, что порт не работает.

Для браузера добавь от администратора в Windows
`C:\Windows\System32\drivers\etc\hosts`:

```text
192.168.76.21 app.lab
```

Открой `http://app.lab:30080/health`.
Пустой ADDRESS у Ingress при NodePort в bare-metal стенде возможен;
проверяй Service и реальный HTTP-запрос.

### Дополнительно: вход через внешний интерфейс NAT-шлюза

Если проверяющему нужен вход не из VMnet1, а через WAN gateway-vm:
1. На gateway-vm раскомментируй DNAT-строку в /etc/nftables.conf:
   WAN:8080 → 192.168.76.21:30080. Проверь имя WAN-интерфейса.
2. Проверь и применяй:

```bash
sudo nft -c -f /etc/nftables.conf
sudo systemctl restart nftables
ip -4 address show ens33
```

3. С Windows отправь запрос на **WAN-адрес gateway-vm**:

```powershell
curl.exe -i -X POST http://<IP_GATEWAY_WAN>:8080/ -H "Host: app.lab" -H "Test: Hello"
```

Для другого компьютера физической сети можно добавить в VMware VMnet8
NAT Settings проброс **Windows-host:18080 → gateway-WAN:8080**
и разрешить вход 18080 в Windows Firewall для нужной локальной сети.
Тогда проверяющий использует IP Windows-хоста и порт 18080 с Host: app.lab.
При таком пробросе закрепи WAN-адрес шлюза, чтобы DHCP не сменил назначение.

Для выхода внутренних VM наружу этот DNAT не нужен; его роль - входящий доступ.

## 11. Диагностика

| Симптом | Что проверить |
| --- | --- |
| /health = 503 | ping 77.88.8.8 из VM/контейнера, CAP_NET_RAW, NAT, ICMP-фильтрацию |
| DNS не работает | Netplan nameservers, resolvectl status, путь наружу через gateway |
| systemd не запускается | journalctl -u service-lab; путь venv; занятость 8000 |
| app Docker unhealthy | docker compose logs app; доступность /metrics; это не проверка внешнего ping |
| Prometheus target DOWN | имена app/blackbox в Docker-сети, docker compose logs |
| ErrImageNeverPull | импорт образа в containerd namespace k8s.io на ВСЕХ нодах, совпадение tag |
| Node NotReady / CoreDNS Pending | Flannel, /opt/cni/bin/loopback, swap, cgroup, firewall |
| Ingress 404 | правильный Host: app.lab; ingressClassName; Traefik запущен |
| Ingress 502/503 | Ready Pod, Service selector/targetPort, Pod-сеть |
| NodePort timeout | VMnet1 хоста, IP ноды, firewall, Service Traefik, kube-proxy |
| Kubernetes /health = 503 | ping из Pod; маршрут ноды через NAT; Flannel masquerading и NET_RAW |

Полезные команды на control plane:

```bash
kubectl -n service-lab describe pod <ИМЯ_POD>
kubectl -n service-lab logs deployment/service-lab --tail=100
kubectl -n service-lab exec deployment/service-lab -- /usr/bin/ping -c 1 -W 2 77.88.8.8
kubectl -n service-lab get endpointslices
kubectl -n traefik logs deployment/traefik --tail=100
kubectl -n kube-flannel logs daemonset/kube-flannel-ds --tail=100
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 100 --no-pager
```

Для обновления приложения используй **новый tag** (например 1.0.1):
собери новый образ, импортируй на все ноды, обнови image в manifest и apply.
Повторное использование старого tag + Never может оставить старый образ/Pod.

## 12. Что показать при сдаче

| Пункт | Подтверждение |
| --- | --- |
| a | curl с Test: Hello = 200; без/неверный = 403; /health = 200 OK |
| b | Ubuntu 22.04; systemctl status/show; процесс от labapp; автозапуск |
| c | Dockerfile; docker build; docker images service-lab |
| d | compose.yaml; Targets/Alerts/UI; тест остановки приложения; 2 NIC шлюза; nft rules |
| e | app-vm только VMnet1; ip route get 77.88.8.8 via .254; успешный ping наружу |
| f | 3 VM и kubectl get nodes: 3 Ready |
| g | Deployment, 2 Ready Pod, Service |
| h | Ingress + Traefik Service NodePort; curl с Windows через 30080, без port-forward |

Сохрани скриншоты, вывод проверок и проект в репозиторий.
Не публикуй /etc/kubernetes/admin.conf, токены join и SSH private keys.

## 13. Проверка самого проекта

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q
bash -n scripts/*.sh
sudo bash scripts/verify-configs.sh
```

В подготовленном проекте проверены HTTP-логика/ошибки ping тестами,
синтаксис shell и структура YAML. Реальная сборка Docker,
NAT VMware и Kubernetes здесь не запускались: эти проверки выполняются на твоём стенде.
Тесты приложения подменяют сетевой ответ; доказательство реального ping - curl /health
и ping внутри твоей VM/контейнера/Pod.

## Официальные источники

- Ubuntu Server 22.04 ISO: https://releases.ubuntu.com/22.04/
- VMware networks: https://knowledge.broadcom.com/external/article?legacyId=1018697
- Docker Ubuntu: https://docs.docker.com/engine/install/ubuntu/
- kubeadm 1.36: https://v1-36.docs.kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Container runtimes 1.36: https://v1-36.docs.kubernetes.io/docs/setup/production-environment/container-runtimes/
- Flannel: https://github.com/flannel-io/flannel
- Helm: https://helm.sh/docs/intro/install/
- Traefik chart: https://github.com/traefik/traefik-helm-chart
- Prometheus blackbox pattern: https://prometheus.io/docs/guides/multi-target-exporter/
- Alertmanager: https://prometheus.io/docs/alerting/latest/configuration/
