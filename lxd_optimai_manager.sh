#!/bin/bash
set -e

# Глобальная переменная для префикса контейнеров
CONTAINER_PREFIX="node"
# Файл для хранения учетных данных
CREDENTIALS_FILE="/root/.optimai_credentials"

# Проверка root прав
if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт с sudo: sudo bash lxd_optimai_manager.sh"
    exit 1
fi

# Обработка Ctrl+C — выход без ошибки
trap 'echo ""; echo "⛔ Прервано пользователем (Ctrl+C)"; exit 0' INT

# ============================================
# БЛОК 1: УСТАНОВКА И НАСТРОЙКА LXD
# ============================================

update_system() {
    echo ""
    echo "=========================================="
    echo " [1/3] ОБНОВЛЕНИЕ СИСТЕМЫ"
    echo "=========================================="
    echo ""
    echo "=== Проверка состояния VPS ==="
    echo "Hostname: $(hostname)"
    echo "OS: $(lsb_release -d | cut -f2)"
    echo "Kernel: $(uname -r)"
    echo "CPU cores: $(nproc)"
    echo "RAM: $(free -h | grep Mem | awk '{print $2}')"
    echo "Disk: $(df -h / | tail -1 | awk '{print $2}')"
    echo ""
    echo "=== Обновление пакетов ==="
    apt update && apt upgrade -y
    echo ""
    echo "=== Установка зависимостей ==="
    apt install -y --no-install-recommends snapd curl ca-certificates gnupg
    echo ""
    echo "✅ Система обновлена"
    read -p "Нажми Enter для продолжения..."
}

install_lxd() {
    echo ""
    echo "=========================================="
    echo " [2/3] УСТАНОВКА И ПОДГОТОВКА LXD"
    echo "=========================================="

    echo "=== Подготовка хост-системы ==="
    modprobe overlay
    modprobe br_netfilter
    echo "overlay" > /etc/modules-load.d/lxd-docker.conf
    echo "br_netfilter" >> /etc/modules-load.d/lxd-docker.conf
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "✅ Хост подготовлен (модули загружены)"

    EXISTING_CONTAINERS=$(lxc list -c n --format csv 2>/dev/null | grep -E "^${CONTAINER_PREFIX}[0-9]+" | wc -l)
    if [ "$EXISTING_CONTAINERS" -gt 0 ]; then
        MAX_EXISTING=$(lxc list -c n --format csv | grep -E "^${CONTAINER_PREFIX}[0-9]+" | sed "s/${CONTAINER_PREFIX}//" | sort -n | tail -1)
        echo "Найдено контейнеров: $EXISTING_CONTAINERS, Max ID: ${CONTAINER_PREFIX}${MAX_EXISTING}"
    else
        EXISTING_CONTAINERS=0
        MAX_EXISTING=0
    fi

    if ! command -v lxc >/dev/null 2>&1; then
        echo "=== Установка LXD через snap ==="
        snap install lxd --channel=5.21/stable
        sleep 5
        lxd init --auto
    else
        echo "✓ LXD уже установлен"
    fi

    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        lxc network create lxdbr0 ipv4.nat=true ipv6.address=none
    fi
    if ! lxc storage show default >/dev/null 2>&1; then
        lxc storage create default dir
    fi

    lxc profile device remove default eth0 2>/dev/null || true
    lxc profile device add default eth0 nic name=eth0 network=lxdbr0 2>/dev/null || true
    lxc profile device remove default root 2>/dev/null || true
    lxc profile device add default root disk path=/ pool=default 2>/dev/null || true

    read -p "Сколько ВСЕГО контейнеров нужно? [1-30, сейчас: $EXISTING_CONTAINERS]: " TOTAL_CONTAINERS
    if ! [[ "$TOTAL_CONTAINERS" =~ ^[0-9]+$ ]] || [ "$TOTAL_CONTAINERS" -le "$EXISTING_CONTAINERS" ]; then
        echo "⚠️ Новые контейнеры не требуются или введено неверное число"
        read -p "Нажмите Enter..." && return
    fi

    for i in $(seq $((MAX_EXISTING + 1)) $TOTAL_CONTAINERS); do
        name="${CONTAINER_PREFIX}${i}"
        echo "🚀 Создаю и настраиваю $name..."
        lxc launch ubuntu:22.04 "$name" || continue
        lxc config set "$name" security.privileged true
        lxc config set "$name" security.nesting true
        lxc config set "$name" linux.kernel_modules overlay,br_netfilter,ip_tables,iptable_nat,xt_conntrack
        lxc config set "$name" raw.lxc "lxc.apparmor.profile=unconfined
lxc.mount.auto=proc:rw sys:rw cgroup:rw
lxc.cgroup.devices.allow=a
lxc.cap.drop="
        lxc config set "$name" limits.processes 2500
        lxc restart "$name"
        echo "✓ $name готов к работе"
        sleep 1
    done

    echo ""
    echo "✅ Все новые контейнеры созданы и настроены с поддержкой Docker/Overlay2"
    read -p "Нажмите Enter для продолжения..."
}

setup_swap() {
    echo ""
    echo "=========================================="
    echo " НАСТРОЙКА SWAP ФАЙЛА"
    echo "=========================================="

    echo "=== Текущий SWAP ==="
    CURRENT_SWAP=$(swapon --show --noheadings)
    if [ -n "$CURRENT_SWAP" ]; then
        swapon --show
        SWAP_FILE=$(swapon --show --noheadings | awk '{print $1}' | head -1)
        echo "1) Удалить и создать новый   2) Оставить"
        read -p "[1-2]: " swap_choice
        if [ "$swap_choice" = "2" ]; then
            read -p "Нажми Enter..." && return
        fi
        swapoff "$SWAP_FILE"
        rm -f "$SWAP_FILE"
        sed -i "\|$SWAP_FILE|d" /etc/fstab
    fi

    read -p "Размер SWAP в GB [1-128]: " SWAP_SIZE
    if ! [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE" -lt 1 ] || [ "$SWAP_SIZE" -gt 128 ]; then
        echo "❌ Неверный размер"
        read -p "Нажми Enter..." && return
    fi

    SWAP_FILE="/swapfile"
    echo "Создаю ${SWAP_SIZE}GB..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1G count=$SWAP_SIZE status=progress
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    echo "✓ SWAP готов"
    swapon --show
    free -h | grep -E "Mem|Swap"
    read -p "Нажми Enter..."
}

setup_docker() {
    echo ""
    echo "=========================================="
    echo "  [3/3] НАСТРОЙКА DOCKER (ULTRA-FIXED)"
    echo "=========================================="

    CONTAINERS=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}")
    [ -z "$CONTAINERS" ] && { echo "❌ Контейнеры не найдены"; read -p "Enter..."; return; }

    for container in $CONTAINERS; do
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║  Настройка: $container"
        echo "╚══════════════════════════════════════╝"

        DOCKER_OK=$(lxc exec $container -- bash -c '
            if command -v docker >/dev/null 2>&1; then
                DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
                [ "$DRIVER" = "overlay2" ] && echo "ok"
            fi
        ' 2>/dev/null || echo "error")

        if [ "$DOCKER_OK" = "ok" ]; then
            echo "✓ Docker уже установлен и overlay2 активен, пропускаем"
            continue
        fi

        echo "⏳ Ждем 2 секунды после запуска контейнера..."
        sleep 2

        ATTEMPT=0
        SUCCESS=false
        set +e  # временно отключаем set -e чтобы retry мог сработать
        while [ $ATTEMPT -lt 2 ]; do
            ATTEMPT=$((ATTEMPT + 1))
            [ $ATTEMPT -gt 1 ] && echo "🔄 Попытка $ATTEMPT: перезапускаю контейнер и пробую снова..." && lxc restart "$container" && sleep 3

            lxc exec $container -- bash <<'EOF'
set -e

echo ""
echo "════════════════════════════════════════"
echo " УСТАНОВКА DOCKER С OVERLAY2 ДРАЙВЕРОМ"
echo "════════════════════════════════════════"
echo ""

echo "[1/4] Очистка старых версий Docker..."
systemctl stop docker 2>/dev/null || true
apt-get remove -y docker docker-engine docker.io containerd runc \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
rm -rf /var/lib/docker /etc/docker
# Убираем репозиторий docker чтобы install script не ругался
rm -f /etc/apt/sources.list.d/docker.list
rm -f /usr/bin/docker /usr/local/bin/docker

echo "[2/4] Установка свежего Docker..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm /tmp/get-docker.sh

echo "[3/4] Настройка overlay2 драйвера..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON

echo "[4/4] Запуск Docker..."
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

echo "  → Ждём готовности Docker..."
for i in $(seq 1 15); do
    docker info >/dev/null 2>&1 && break
    sleep 1
done

echo ""
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "ОШИБКА")
if [ "$DRIVER" = "overlay2" ]; then
    echo "✅ Storage Driver: overlay2 (ОК)"
else
    echo "❌ Storage Driver: $DRIVER (НЕ ОК!)"
    docker info
    exit 1
fi

echo ""
echo "✅ Docker настроен корректно!"
docker --version
docker info | grep -E "Storage Driver|Logging Driver"
EOF

            if [ $? -eq 0 ]; then
                SUCCESS=true
                break
            fi
        done

        if [ "$SUCCESS" = "true" ]; then
            echo "✅ $container готов"
        else
            echo "❌ Ошибка настройки $container после 2 попыток, пропускаю"
        fi
        set -e  # включаем set -e обратно
        sleep 2
    done

    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  ✅ Docker + overlay2 настроены!     ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Нажми Enter..."
}

# ============================================
# БЛОК 2: УСТАНОВКА И ЛОГИН OPTIMAI
# ============================================

get_max_container() {
    local max_num=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}[0-9]" | sed "s/${CONTAINER_PREFIX}//" | sort -n | tail -1)
    [ -z "$max_num" ] && echo "30" || echo "$max_num"
}

parse_range() {
    local input=$1
    local max=$(get_max_container)
    [ -z "$input" ] && echo "1 $max" && return 0

    if [[ $input == *"-"* ]]; then
        start=$(echo $input | cut -d'-' -f1)
        end=$(echo $input | cut -d'-' -f2)
    else
        start=$input
        end=$input
    fi

    if ! [[ "$start" =~ ^[0-9]+$ ]] || ! [[ "$end" =~ ^[0-9]+$ ]]; then
        echo "ERROR: число или диапазон"
        return 1
    fi
    if [ "$start" -lt 1 ] || [ "$start" -gt "$max" ] || [ "$end" -lt 1 ] || [ "$end" -gt "$max" ] || [ "$start" -gt "$end" ]; then
        echo "ERROR: неверный диапазон"
        return 1
    fi
    echo "$start $end"
    return 0
}

install_optimai() {
    echo ""
    echo "=========================================="
    echo " УСТАНОВКА OPTIMAI CLI + DOCKER ОБРАЗ"
    echo "=========================================="

    local max=$(get_max_container)
    echo "В какие контейнеры? (5, 1-10, Enter=все 1-$max)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    # ──────────────────────────────────────────────────────
    # ШАГ 1: Автоматическая настройка локального registry
    # Образ скачивается ОДИН РАЗ на хост, остальные
    # контейнеры тянут по локальной сети без интернета
    # ──────────────────────────────────────────────────────
    echo ""
    echo "=== [1/3] Подготовка локального Docker Registry ==="

    BRIDGE_IP=$(ip addr show lxdbr0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    USE_LOCAL=false

    if [ -z "$BRIDGE_IP" ]; then
        echo "  ⚠️  lxdbr0 не найден, образ будет скачиваться из интернета"
    else
        # Устанавливаем Docker на хосте если нет
        if ! command -v docker >/dev/null 2>&1; then
            echo "  → Устанавливаю Docker на хост..."
            curl -fsSL https://get.docker.com -o /tmp/get-docker-host.sh
            sh /tmp/get-docker-host.sh
            rm /tmp/get-docker-host.sh
            systemctl enable docker
            systemctl start docker
            sleep 3
        fi

        # ── Настройка insecure-registry на ХОСТЕ ────────────
        echo "  → Настройка insecure-registry на хосте..."
        if [ -f /etc/docker/daemon.json ]; then
            if ! grep -q "insecure-registries" /etc/docker/daemon.json; then
                python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    d = json.load(f)
d['insecure-registries'] = ['${BRIDGE_IP}:5000']
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(d, f, indent=2)
"
                systemctl restart docker && sleep 3
                echo "  ✓ daemon.json обновлён, Docker перезапущен"
            else
                echo "  ✓ insecure-registry уже настроен на хосте"
            fi
        else
            mkdir -p /etc/docker
            cat > /etc/docker/daemon.json <<JSON
{
  "insecure-registries": ["${BRIDGE_IP}:5000"]
}
JSON
            systemctl restart docker && sleep 3
            echo "  ✓ daemon.json создан, Docker перезапущен"
        fi
        # ────────────────────────────────────────────────────

        # Запускаем registry если не запущен
        if ! docker ps | grep -q local-registry; then
            echo "  → Запускаю локальный registry на $BRIDGE_IP:5000..."
            docker stop local-registry 2>/dev/null || true
            docker rm local-registry 2>/dev/null || true
            docker run -d \
                --name local-registry \
                --restart=always \
                -p 5000:5000 \
                -v /var/lib/local-registry:/var/lib/registry \
                registry:2
            sleep 2
            echo "  ✓ Registry запущен"
        else
            echo "  ✓ Registry уже запущен"
        fi

        # Скачиваем образ и пушим в registry (только если его там нет)
        if curl -sf "http://${BRIDGE_IP}:5000/v2/crawl4ai/tags/list" | grep -q "0.7.3" 2>/dev/null; then
            echo "  ✓ Образ уже есть в registry — интернет не нужен"
        else
            echo "  → Скачиваю образ из интернета (один раз для всех контейнеров)..."
            if ! docker images | grep -q "unclecode/crawl4ai.*0.7.3"; then
                docker pull unclecode/crawl4ai:0.7.3
            fi
            docker tag unclecode/crawl4ai:0.7.3 "${BRIDGE_IP}:5000/crawl4ai:0.7.3"
            docker push "${BRIDGE_IP}:5000/crawl4ai:0.7.3"
            echo "  ✓ Образ загружен в registry"
        fi

        USE_LOCAL=true
    fi

    # ──────────────────────────────────────────────────────
    # ШАГ 2: Установка CLI и образа в каждый контейнер
    # ──────────────────────────────────────────────────────
    echo ""
    echo "=== [2/3] Установка в контейнеры ==="

    # Кешируем список контейнеров один раз
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        echo ""
        echo "─── ${CONTAINER_PREFIX}${i} ───────────────────────────────"
        echo "$LXC_LIST" | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "  нет контейнера, пропускаю"; continue; }

        # Установка CLI
        if lxc exec ${CONTAINER_PREFIX}${i} -- test -f /usr/local/bin/optimai-cli 2>/dev/null; then
            echo "  ✓ optimai-cli уже установлен"
        else
            echo "  → Устанавливаю optimai-cli..."
            lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
                curl -L https://optimai.network/download/cli-node/linux -o /tmp/optimai-cli &&
                chmod +x /tmp/optimai-cli &&
                mv /tmp/optimai-cli /usr/local/bin/optimai-cli
            " && echo "  ✓ optimai-cli установлен" || echo "  ❌ Ошибка установки CLI"
        fi

        # Установка Docker образа
        IMAGE_EXISTS=$(lxc exec ${CONTAINER_PREFIX}${i} -- bash -c \
            'docker images 2>/dev/null | grep -q "unclecode/crawl4ai.*0.7.3" && echo "yes" || echo "no"')

        if [ "$IMAGE_EXISTS" = "yes" ]; then
            echo "  ✓ Docker образ crawl4ai уже есть"
        elif [ "$USE_LOCAL" = "true" ]; then
            echo "  → Тяну образ с хоста ($BRIDGE_IP:5000) без интернета..."

            PULL_OK=false
            for attempt in 1 2 3; do
                [ $attempt -gt 1 ] && echo "  🔄 Попытка $attempt..."
                lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
                    mkdir -p /etc/docker
                    if [ -f /etc/docker/daemon.json ]; then
                        if ! grep -q 'insecure-registries' /etc/docker/daemon.json; then
                            python3 -c \"
import json
with open('/etc/docker/daemon.json') as f:
    d = json.load(f)
d['insecure-registries'] = ['${BRIDGE_IP}:5000']
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(d, f, indent=2)
\"
                            systemctl restart docker && sleep 3
                        fi
                    else
                        cat > /etc/docker/daemon.json <<JSON
{
  \"storage-driver\": \"overlay2\",
  \"insecure-registries\": [\"${BRIDGE_IP}:5000\"],
  \"log-driver\": \"json-file\",
  \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"}
}
JSON
                        systemctl restart docker && sleep 3
                    fi
                    docker pull ${BRIDGE_IP}:5000/crawl4ai:0.7.3 &&
                    docker tag ${BRIDGE_IP}:5000/crawl4ai:0.7.3 unclecode/crawl4ai:0.7.3
                " && { PULL_OK=true; break; } || sleep 5
            done

            if [ "$PULL_OK" = "true" ]; then
                echo "  ✓ Образ установлен с локального registry"
            else
                echo "  ❌ Ошибка загрузки образа после 3 попыток"
            fi
        else
            echo "  → Скачиваю образ из интернета..."
            lxc exec ${CONTAINER_PREFIX}${i} -- bash -c \
                "docker pull unclecode/crawl4ai:0.7.3" \
                && echo "  ✓ Образ скачан" || echo "  ❌ Ошибка скачивания"
        fi
    done

    # ── Очистка образа с хоста после раздачи по контейнерам ──
    if [ "$USE_LOCAL" = "true" ]; then
        echo ""
        echo "=== [3/3] Очистка образа на хосте ==="
        docker rmi "${BRIDGE_IP}:5000/crawl4ai:0.7.3" 2>/dev/null && \
            echo "  ✓ Удалён тег ${BRIDGE_IP}:5000/crawl4ai:0.7.3" || \
            echo "  — тег уже удалён"
        docker rmi "unclecode/crawl4ai:0.7.3" 2>/dev/null && \
            echo "  ✓ Удалён образ unclecode/crawl4ai:0.7.3" || \
            echo "  — образ уже удалён"
        echo "  ✓ Место на хосте освобождено"
    fi
    # ─────────────────────────────────────────────────────────

    echo ""
    echo "✅ Установка завершена"
    read -p "Нажми Enter..."
}

# ============================================
# ИСПРАВЛЕНО: Обновление через optimai-cli update
# ============================================
update_optimai() {
    echo ""
    echo "=========================================="
    echo " ОБНОВЛЕНИЕ OPTIMAI CLI"
    echo "=========================================="
    local max=$(get_max_container)
    echo "Где обновить? (5, 1-10, Enter=все)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        echo "$LXC_LIST" | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "нет"; continue; }
        lxc exec ${CONTAINER_PREFIX}${i} -- /usr/local/bin/optimai-cli update && echo "OK" || echo "ошибка"
    done
    echo ""
    echo "Обновление завершено"
    read -p "Нажми Enter..."
}

login_optimai() {
    echo ""
    echo "=========================================="
    echo " ЛОГИН OPTIMAI"
    echo "=========================================="

    if [ -f "$CREDENTIALS_FILE" ]; then
        echo "Сохранённые учетные данные найдены. Выберите действие: 1 — использовать сохранённые данные, 2 — ввести новые."
        read -p "[1-2]: " ch
        if [ "$ch" = "1" ]; then
            source "$CREDENTIALS_FILE"
        else
            read -p "Email: " OPTIMAI_LOGIN
            read -sp "Пароль: " OPTIMAI_PASSWORD; echo
            echo "OPTIMAI_LOGIN=\"$OPTIMAI_LOGIN\"" > "$CREDENTIALS_FILE"
            echo "OPTIMAI_PASSWORD=\"$OPTIMAI_PASSWORD\"" >> "$CREDENTIALS_FILE"
            chmod 600 "$CREDENTIALS_FILE"
        fi
    else
        read -p "Email: " OPTIMAI_LOGIN
        read -sp "Пароль: " OPTIMAI_PASSWORD; echo
        echo "OPTIMAI_LOGIN=\"$OPTIMAI_LOGIN\"" > "$CREDENTIALS_FILE"
        echo "OPTIMAI_PASSWORD=\"$OPTIMAI_PASSWORD\"" >> "$CREDENTIALS_FILE"
        chmod 600 "$CREDENTIALS_FILE"
    fi

    echo ""
    echo "В какие контейнеры? (5, 1-10, Enter=все)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Нажми Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    # Кешируем список контейнеров один раз
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        if ! echo "$LXC_LIST" | grep -q "^${CONTAINER_PREFIX}${i}$"; then
            echo "нет"
            continue
        fi

        lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
            [ -f /usr/local/bin/optimai-cli ] || { echo 'CLI не установлен'; exit 1; }
            command -v expect >/dev/null || { apt-get update -qq && apt-get install -y --no-install-recommends expect -qq >/dev/null; }
            expect <<'EOF'
set timeout 60
spawn /usr/local/bin/optimai-cli auth login --legacy
expect {
    \"Already logged in\" {
        puts \"✓ Уже залогинен\"
        exit 0
    }
    \"Email:\" {
        sleep 1
        send \"$OPTIMAI_LOGIN\r\"
        expect \"Password:\" {
            sleep 2
            send \"$OPTIMAI_PASSWORD\r\"
            expect {
                \"Signed in successfully\" {
                    puts \"✓ Успешный вход\"
                    exit 0
                }
                \"Invalid\" {
                    puts \"✗ Неверный логин или пароль\"
                    exit 1
                }
                timeout {
                    puts \"✗ Таймаут после пароля\"
                    exit 1
                }
            }
        }
        timeout {
            puts \"✗ Нет поля Password\"
            exit 1
        }
    }
    timeout {
        puts \"✗ Нет поля Email\"
        exit 1
    }
}
EOF
        " && echo "OK" || echo "FAIL"
        sleep 1
    done

    echo ""
    echo "Логин завершён"
    read -p "Нажми Enter..."
}

# ============================================
# БЛОК 3: УПРАВЛЕНИЕ НОДАМИ
# ============================================

start_nodes() {
    local max=$(get_max_container)
    echo "Какие ноды запустить? (например: 5, 1-10 или Enter для всех 1-$max)"
    read -r range
    result=$(parse_range "$range")
    if [ $? -ne 0 ]; then
        echo "✗ $result"
        read -p "Нажми Enter для продолжения..."
        return
    fi
    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    if [ "$start" -eq "$end" ]; then
        echo "Запуск ${CONTAINER_PREFIX}${start}..."
    else
        echo "Запуск нод с ${CONTAINER_PREFIX}${start} по ${CONTAINER_PREFIX}${end}..."
    fi

    for i in $(seq $start $end); do
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║  Запуск ${CONTAINER_PREFIX}${i}"
        echo "╚══════════════════════════════════════╝"

        lxc exec ${CONTAINER_PREFIX}${i} -- bash << 'SCRIPT'
set -e

mkdir -p /var/log/optimai

echo "[1/6] Остановка старых процессов..."
pkill -9 -f 'optimai-cli' 2>/dev/null || true
docker stop optimai_crawl4ai_0_7_3 2>/dev/null || true
docker rm optimai_crawl4ai_0_7_3 2>/dev/null || true
sleep 2

echo "[2/6] Проверка Docker..."
if ! systemctl is-active docker >/dev/null 2>&1; then
    echo "→ Запуск Docker..."
    systemctl start docker
    for i in $(seq 1 15); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
fi

echo "[3/6] Проверка storage driver..."
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
if [ "$DRIVER" != "overlay2" ]; then
    echo "❌ КРИТИЧНО: Docker использует '$DRIVER' вместо overlay2!"
    echo "Запусти пункт 3 (Настройка Docker) из главного меню"
    exit 1
fi
echo "✓ Storage Driver: overlay2"

echo "[4/6] Проверка optimai-cli..."
if [ ! -f /usr/local/bin/optimai-cli ]; then
    echo "✗ ОШИБКА: optimai-cli не найден!"
    exit 1
fi

echo "[5/6] Запуск ноды..."
cd /root
rm -f /var/log/optimai/node.log
nohup /usr/local/bin/optimai-cli node start >> /var/log/optimai/node.log 2>&1 &
sleep 5

echo "[6/6] Проверка запуска..."
if pgrep -f 'optimai-cli' >/dev/null; then
    PID=$(pgrep -f 'optimai-cli')
    echo "✅ Процесс запущен (PID: $PID)"
    echo ""
    echo "Первые строки лога:"
    head -20 /var/log/optimai/node.log 2>/dev/null || echo "Лог пуст"
else
    echo "❌ Ошибка запуска!"
    if [ -f /var/log/optimai/node.log ]; then
        cat /var/log/optimai/node.log
    else
        echo "Лог файл не создан"
    fi
    exit 1
fi
SCRIPT

        if [ $? -eq 0 ]; then
            echo "✅ ${CONTAINER_PREFIX}${i} запущен"
        else
            echo "❌ Ошибка запуска ${CONTAINER_PREFIX}${i}"
        fi
        sleep 2
    done

    echo ""
    echo "✅ Запуск завершен"
    read -p "Нажми Enter для продолжения..."
}

# ============================================
# ИСПРАВЛЕНО: Остановка нод
# ============================================
stop_nodes() {
    local max=$(get_max_container)
    echo "Какие ноды остановить? (5, 1-10, Enter для всех 1-$max)"
    read -r range

    result=$(parse_range "$range")
    if [ $? -ne 0 ]; then
        echo "✗ $result"
        read -p "Enter..."
        return
    fi

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    echo "Останавливаю ноды с ${CONTAINER_PREFIX}${start} по ${CONTAINER_PREFIX}${end}..."

    # Кешируем список контейнеров один раз
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        container="${CONTAINER_PREFIX}${i}"
        if ! echo "$LXC_LIST" | grep -q "^${container}$"; then
            echo "[$i] $container: не найден, пропускаю"
            continue
        fi
        echo -n "[$i] $container: "
        lxc exec "$container" -- bash -c '
            # 1. Убиваем все процессы optimai
            pkill -9 -f "optimai-cli" 2>/dev/null || true
            pkill -9 -f "optimai" 2>/dev/null || true
            sleep 1
            # 2. Останавливаем и удаляем все docker контейнеры
            if command -v docker >/dev/null 2>&1; then
                docker ps -q | xargs -r docker stop --time=5 2>/dev/null || true
            fi
        ' || true
        echo "✓ остановлен"
    done

    echo ""
    echo "✅ Остановка завершена"
    read -p "Нажми Enter..."
}

# ============================================
# ФУНКЦИЯ: Удаление контейнеров LXD
# ============================================
delete_containers() {
    local max=$(get_max_container)
    echo ""
    echo "=========================================="
    echo " УДАЛЕНИЕ КОНТЕЙНЕРОВ LXD"
    echo "=========================================="
    echo ""
    echo "Укажи что удалить:"
    echo "  • Один контейнер:  5"
    echo "  • Диапазон:        3-7"
    echo "  • Все контейнеры:  Enter"
    echo ""
    read -p "Номер или диапазон (1-$max): " range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    if [ "$start" -eq "$end" ]; then
        echo ""
        echo "⚠️  Будет удалён контейнер: ${CONTAINER_PREFIX}${start}"
    else
        echo ""
        echo "⚠️  Будут удалены контейнеры: ${CONTAINER_PREFIX}${start} — ${CONTAINER_PREFIX}${end} ($((end - start + 1)) шт.)"
    fi

    read -p "Подтвердить удаление? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Отмена"; read -p "Enter..."; return; }

    # Кешируем список контейнеров один раз
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        container="${CONTAINER_PREFIX}${i}"
        if ! echo "$LXC_LIST" | grep -q "^${container}$"; then
            echo "[$i] $container: не найден, пропускаю"
            continue
        fi
        echo -n "[$i] $container: останавливаю... "
        lxc stop "$container" --force 2>/dev/null || true
        echo -n "удаляю... "
        lxc delete "$container" 2>/dev/null || true
        echo "✓ удалён"
    done

    echo ""
    echo "✅ Удаление завершено"
    read -p "Нажми Enter..."
}


view_logs() {
    local max=$(get_max_container)
    echo "Номер контейнера (1-$max):"
    read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$max" ] && { echo "Неверно"; read -p "Enter..."; return; }

    echo "=== Логи ${CONTAINER_PREFIX}${num} ==="
    lxc exec ${CONTAINER_PREFIX}${num} -- bash -c '
        if [ -f /var/log/optimai/node.log ]; then
            tail -50 /var/log/optimai/node.log
        else
            echo "Логов нет"
            ps aux | grep optimai | grep -v grep || echo "Процесс не запущен"
        fi
    '
    echo ""
    read -p "Следить в реальном времени? (y/n): " follow
    [ "$follow" = "y" ] && lxc exec ${CONTAINER_PREFIX}${num} -- tail -f /var/log/optimai/node.log
}

check_status() {
    echo "=== СТАТУС НОД ==="
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq 1 $(get_max_container)); do
        if echo "$LXC_LIST" | grep -q "^${CONTAINER_PREFIX}${i}$"; then
            result=$(lxc exec ${CONTAINER_PREFIX}${i} -- bash -c '
                PROC=$(pgrep -f "optimai-cli" >/dev/null 2>&1 && echo "yes" || echo "no")
                DOCKER=$(docker ps 2>/dev/null | grep -q "optimai_crawl4ai" && echo "yes" || echo "no")
                if [ "$PROC" = "yes" ] && [ "$DOCKER" = "yes" ]; then
                    echo "RUNNING"
                elif [ "$PROC" = "yes" ] && [ "$DOCKER" = "no" ]; then
                    echo "CRASHED"
                else
                    echo "STOPPED"
                fi
                docker info --format "{{.Driver}}" 2>/dev/null || echo "none"
            ') || true

            node_status=$(echo "$result" | head -1)
            driver=$(echo "$result" | tail -1)

            case "$node_status" in
                RUNNING) status="🟢 РАБОТАЕТ" ;;
                CRASHED) status="🟡 DOCKER ОСТАНОВЛЕН" ;;
                *)       status="🔴 ОСТАНОВЛЕНА" ;;
            esac

            echo "${CONTAINER_PREFIX}${i}: $status | Docker: $driver"
        fi
    done
    read -p "Нажми Enter..."
}


# === Главное меню ===
while true; do
    clear
    echo "=========================================="
    echo " LXD + DOCKER + OPTIMAI MANAGER v2.1"
    echo "=========================================="
    echo ""

    echo "=== УСТАНОВКА И НАСТРОЙКА ==="
    echo "1) Обновление системы"
    echo "2) Установка LXD и создание контейнеров"
    echo "3) Настройка Docker внутри контейнеров"
    echo "4) Установка OptimAI CLI в контейнеры"
    echo ""

    echo "=== УПРАВЛЕНИЕ OPTIMAI НОДАМИ ==="
    echo "5) Логин OptimAI в контейнерах"
    echo "6) Запустить ноды"
    echo "7) Остановить ноды"
    echo "8) Посмотреть логи"
    echo "9) Проверить статус всех нод"
    echo ""

    echo "=== ДОПОЛНИТЕЛЬНО ==="
    echo "10) Настройка SWAP файла"
    echo "11) Обновление OptimAI CLI"
    echo "12) Удалить контейнеры LXD "
    echo "13) Выход"
    echo "=========================================="

    read -p "Выбери пункт [1-13]: " choice
    echo ""

    case $choice in
        1) update_system ;;
        2) install_lxd ;;
        3) setup_docker ;;
        4) install_optimai ;;
        5) login_optimai ;;
        6) start_nodes ;;
        7) stop_nodes ;;
        8) view_logs ;;
        9) check_status ;;
        10) setup_swap ;;
        11) update_optimai ;;
        12) delete_containers ;;
        13) echo "Выход..."; exit 0 ;;
        *) echo "Неверный выбор"; sleep 2 ;;
    esac
done
