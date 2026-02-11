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
    apt install -y snapd curl ca-certificates gnupg
    echo ""
    echo "✅ Система обновлена"
    read -p "Нажми Enter для продолжения..."
}

install_lxd() {
    echo ""
    echo "=========================================="
    echo " [2/3] УСТАНОВКА И ПОДГОТОВКА LXD"
    echo "=========================================="

    # --- ШАГ 0: ПОДГОТОВКА ХОСТА (VPS) ---
    echo "=== Подготовка хост-системы ==="
    # Загружаем модули ядра на хосте, иначе overlay2 в контейнере не заработает
    modprobe overlay
    modprobe br_netfilter
    
    # Добавляем в автозагрузку хоста
    echo "overlay" > /etc/modules-load.d/lxd-docker.conf
    echo "br_netfilter" >> /etc/modules-load.d/lxd-docker.conf
    
    # Разрешаем пересылку трафика (нужно для сети Docker)
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "✅ Хост подготовлен (модули загружены)"

    # --- ШАГ 1: ПРОВЕРКА СУЩЕСТВУЮЩИХ ---
    EXISTING_CONTAINERS=$(lxc list -c n --format csv 2>/dev/null | grep -E "^${CONTAINER_PREFIX}[0-9]+" | wc -l)
    if [ "$EXISTING_CONTAINERS" -gt 0 ]; then
        MAX_EXISTING=$(lxc list -c n --format csv | grep -E "^${CONTAINER_PREFIX}[0-9]+" | sed "s/${CONTAINER_PREFIX}//" | sort -n | tail -1)
        echo "Найдено контейнеров: $EXISTING_CONTAINERS, Max ID: ${CONTAINER_PREFIX}${MAX_EXISTING}"
    else
        EXISTING_CONTAINERS=0
        MAX_EXISTING=0
    fi

    # --- ШАГ 2: УСТАНОВКА LXD ---
    if ! command -v lxc >/dev/null 2>&1; then
        echo "=== Установка LXD через snap ==="
        snap install lxd --channel=5.21/stable
        sleep 5
        lxd init --auto
    else
        echo "✓ LXD уже установлен"
    fi

    # --- ШАГ 3: НАСТРОЙКА СЕТИ И ХРАНИЛИЩА ---
    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        lxc network create lxdbr0 ipv4.nat=true ipv6.address=none
    fi

    if ! lxc storage show default >/dev/null 2>&1; then
        lxc storage create default dir
    fi

    # Исправление профиля default
    lxc profile device remove default eth0 2>/dev/null || true
    lxc profile device add default eth0 nic name=eth0 network=lxdbr0 2>/dev/null || true
    lxc profile device remove default root 2>/dev/null || true
    lxc profile device add default root disk path=/ pool=default 2>/dev/null || true

    # --- ШАГ 4: СОЗДАНИЕ КОНТЕЙНЕРОВ ---
    read -p "Сколько ВСЕГО контейнеров нужно? [1-30, сейчас: $EXISTING_CONTAINERS]: " TOTAL_CONTAINERS
    if ! [[ "$TOTAL_CONTAINERS" =~ ^[0-9]+$ ]] || [ "$TOTAL_CONTAINERS" -le "$EXISTING_CONTAINERS" ]; then
        echo "⚠️ Новые контейнеры не требуются или введено неверное число"
        read -p "Нажмите Enter..." && return
    fi

    for i in $(seq $((MAX_EXISTING + 1)) $TOTAL_CONTAINERS); do
        name="${CONTAINER_PREFIX}${i}"
        echo "🚀 Создаю и настраиваю $name..."
        
        lxc launch ubuntu:22.04 "$name" || continue

        # ══════════════════════════════════════════════════
        # УСИЛЕННЫЕ НАСТРОЙКИ ДЛЯ DOCKER (OVERLAY2 FIX)
        # ══════════════════════════════════════════════════
        
        # 1. Привилегии и вложенность
        lxc config set "$name" security.privileged true
        lxc config set "$name" security.nesting true
        
        # 2. Проброс модулей ядра
        lxc config set "$name" linux.kernel_modules overlay,br_netfilter,ip_tables,iptable_nat,xt_conntrack
        
        # 3. AppArmor и монтирование (Критично для overlay2)
        lxc config set "$name" raw.lxc "lxc.apparmor.profile=unconfined
lxc.mount.auto=proc:rw sys:rw cgroup:rw
lxc.cgroup.devices.allow=a
lxc.cap.drop="

        # 4. Лимиты
        lxc config set "$name" limits.processes 2500
        
        # Перезагружаем, чтобы все raw.lxc применились сразу
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

        # Проверка: Docker есть и драйвер overlay2 (ФИКС: меняем на overlay2)
        DOCKER_OK=$(lxc exec $container -- bash -c '
            if command -v docker >/dev/null 2>&1; then
                DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
                # Теперь проверяем overlay2 вместо fuse-overlayfs
                [ "$DRIVER" = "overlay2" ] && echo "ok"
            fi
        ')

        if [ "$DOCKER_OK" = "ok" ]; then
            echo "✓ Docker уже установлен и overlay2 активен, пропускаем"
            continue
        fi

        echo "⏳ Ждем 5 секунд после запуска контейнера..."
        sleep 5

        lxc exec $container -- bash <<'EOF'
set -e

echo ""
echo "════════════════════════════════════════"
echo " УСТАНОВКА DOCKER С OVERLAY2 ДРАЙВЕРОМ"
echo "════════════════════════════════════════"
echo ""

# [1/5] Удаляем старый Docker, если есть
echo "[1/5] Очистка старых версий Docker..."
systemctl stop docker 2>/dev/null || true
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
rm -rf /var/lib/docker /etc/docker

# [2/5] Установка Docker с офсайта
echo "[2/5] Установка свежего Docker..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm /tmp/get-docker.sh

# [3/5] Настройка daemon.json для overlay2
echo "[3/5] Настройка overlay2 драйвера..."
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

# [4/5] Запуск Docker
echo "[4/5] Запуск Docker..."
systemctl daemon-reload
systemctl enable docker
systemctl restart docker
sleep 5

# Проверка драйвера
echo ""
echo "════════════════════════════════════════"
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "ОШИБКА")
if [ "$DRIVER" = "overlay2" ]; then
    echo "✅ Storage Driver: overlay2 (ОК)"
else
    echo "❌ Storage Driver: $DRIVER (НЕ ОК!)"
    echo ""
    echo "Полная информация:"
    docker info
    exit 1
fi
echo "════════════════════════════════════════"
echo ""

# [5/5] Скачивание образа crawl4ai
echo "[5/5] Скачивание образа crawl4ai..."
IMAGE="unclecode/crawl4ai:0.7.3"
MAX_RETRIES=3

for attempt in $(seq 1 $MAX_RETRIES); do
    if docker images | grep -q "unclecode/crawl4ai.*0.7.3"; then
        echo "✅ Образ crawl4ai уже есть"
        break
    else
        echo "📦 Попытка $attempt: скачиваем $IMAGE..."
        if timeout 300 docker pull $IMAGE; then
            echo "✅ Образ скачан успешно"
            break
        else
            echo "⚠ Ошибка при скачивании"
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                echo "Ждем 10 секунд перед повтором..."
                sleep 10
            else
                echo "❌ Не удалось скачать после $MAX_RETRIES попыток"
                exit 1
            fi
        fi
    fi
done

echo ""
echo "✅ Docker настроен корректно!"
docker --version
docker info | grep -E "Storage Driver|Logging Driver"
EOF

        if [ $? -eq 0 ]; then
            echo "✅ $container готов"
        else
            echo "❌ Ошибка настройки $container"
        fi
        
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
    echo " УСТАНОВКА OPTIMAI CLI"
    echo "=========================================="
    local max=$(get_max_container)
    echo "В какие контейнеры? (5, 1-10, Enter=все 1-$max)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "нет"; continue; }

        if lxc exec ${CONTAINER_PREFIX}${i} -- test -f /usr/local/bin/optimai-cli 2>/dev/null; then
            echo "уже установлен"
            continue
        fi

        echo "устанавливаю..."
        lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
            curl -L https://optimai.network/download/cli-node/linux -o /tmp/optimai-cli &&
            chmod +x /tmp/optimai-cli &&
            mv /tmp/optimai-cli /usr/local/bin/optimai-cli
        "
    done
    echo ""
    echo "Установка завершена"
    read -p "Нажми Enter..."
}

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

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "нет"; continue; }
        lxc exec ${CONTAINER_PREFIX}${i} -- /usr/local/bin/optimai-cli update 2>/dev/null && echo "OK" || echo "ошибка"
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

    # Получаем логин/пароль
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

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        if ! lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$"; then
            echo "нет"
            continue
        fi

        lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
            [ -f /usr/local/bin/optimai-cli ] || { echo 'CLI не установлен'; exit 1; }
            command -v expect >/dev/null || { apt-get update -qq && apt-get install -y expect -qq >/dev/null; }
            expect <<'EOF'
set timeout 60
spawn /usr/local/bin/optimai-cli auth login
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
    sleep 5
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
    echo ""
    echo "Содержимое лога:"
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


stop_nodes() {
    local max=$(get_max_container)
    echo "Which to stop? (5, 1-10, Enter for all 1-$max)"
    read -r range
    
    # Парсим ввод через существующую функцию parse_range
    result=$(parse_range "$range")
    if [ $? -ne 0 ]; then
        echo "✗ $result"
        read -p "Enter..."
        return
    fi

    # parse_range выдает два числа через пробел (например "1 15")
    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    echo "Stopping nodes from ${CONTAINER_PREFIX}${start} to ${CONTAINER_PREFIX}${end}..."

    # КЛЮЧЕВОЙ ФИКС: Добавлен цикл seq, чтобы пройти по ВСЕМ нодам в диапазоне
    for i in $(seq $start $end); do
        container="${CONTAINER_PREFIX}${i}"
        
        # Проверяем, существует ли контейнер вообще
        if ! lxc list -c n --format csv | grep -q "^${container}$"; then
            echo "[$i] $container: not found, skipping..."
            continue
        fi

        echo -n "[$i] $container: "
        
        # Выполняем команды остановки внутри контейнера
        lxc exec "$container" -- bash -c '
            # Останавливаем CLI процесс
            pkill -9 -f "optimai-cli" 2>/dev/null || true
            # Останавливаем все запущенные докер-контейнеры
            if command -v docker >/dev/null 2>&1; then
                docker stop $(docker ps -q) 2>/dev/null || true
                docker rm $(docker ps -aq) 2>/dev/null || true
            fi
        '
        echo "✓ stopped"
    done

    echo ""
    echo "✅ Stop operation finished"
    read -p "Press Enter..."
}

# ============================================
# ФУНКЦИЯ: Удаление всех контейнеров LXD
# ============================================
delete_all_containers() {
    CONTAINERS=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}")
    if [ -z "$CONTAINERS" ]; then
        echo "Нет контейнеров для удаления"
        read -p "Нажми Enter..." 
        return
    fi

    echo "Будут удалены все контейнеры (${CONTAINER_PREFIX}*):"
    echo "$CONTAINERS"
    read -p "Подтвердить удаление? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Отмена"
        read -p "Enter..." 
        return
    fi

    for c in $CONTAINERS; do
        echo "Останавливаю $c..."
        lxc stop "$c" --force 2>/dev/null || true
        echo "Удаляю $c..."
        lxc delete "$c" 2>/dev/null || echo "Ошибка удаления $c"
    done

    echo "✅ Все контейнеры удалены"
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
    for i in $(seq 1 $(get_max_container)); do
        if lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$"; then
            status=$(lxc exec ${CONTAINER_PREFIX}${i} -- pgrep -f "optimai-cli" >/dev/null 2>&1 && echo "🟢 РАБОТАЕТ" || echo "🔴 ОСТАНОВЛЕНА")
            
            # Дополнительно проверяем драйвер Docker
            driver=$(lxc exec ${CONTAINER_PREFIX}${i} -- docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
            
            echo "${CONTAINER_PREFIX}${i}: $status | Docker: $driver"
        fi
    done
    read -p "Нажми Enter..."
}

# === Главное меню ===
while true; do
    clear
    echo "=========================================="
    echo " LXD + DOCKER + OPTIMAI MANAGER v2.0"
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
    echo "12) Удалить все контейнеры LXD"
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
        12) delete_all_containers ;;
        13) echo "Выход..."; exit 0 ;;
        *) echo "Неверный выбор"; sleep 2 ;;
    esac
done
