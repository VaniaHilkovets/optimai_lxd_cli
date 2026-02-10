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
    echo " [2/3] УСТАНОВКА LXD"
    echo "=========================================="

    # Определяем существующие контейнеры
    EXISTING_CONTAINERS=$(lxc list -c n --format csv 2>/dev/null | grep -E "^${CONTAINER_PREFIX}[0-9]+" | wc -l)
    if [ "$EXISTING_CONTAINERS" -gt 0 ]; then
        MAX_EXISTING=$(lxc list -c n --format csv | grep -E "^${CONTAINER_PREFIX}[0-9]+" | sed "s/${CONTAINER_PREFIX}//" | sort -n | tail -1)
        echo "Найдено существующих контейнеров: $EXISTING_CONTAINERS"
        echo "Максимальный номер: ${CONTAINER_PREFIX}${MAX_EXISTING}"
        echo ""
    else
        EXISTING_CONTAINERS=0
        MAX_EXISTING=0
    fi

    # Установка LXD, если отсутствует
    if ! command -v lxc >/dev/null 2>&1; then
        echo "=== Установка LXD через snap ==="
        snap install lxd --channel=5.21/stable  # Стабильный LTS
        sleep 5

        echo "=== Инициализация LXD ==="
        lxd init --auto || {
            echo "❌ Ошибка автоматической инициализации LXD"
            echo "Попробуйте вручную: lxd init"
            read -p "Нажмите Enter..." && return 1
        }
    else
        echo "✓ LXD уже установлен"
    fi

    # Проверка и создание сети lxdbr0
    echo "=== Проверка/создание сети lxdbr0 ==="
    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        echo "⚠️ Сеть lxdbr0 отсутствует — создаём..."
        lxc network create lxdbr0 ipv4.nat=true ipv6.address=none || {
            echo "❌ Не удалось создать сеть lxdbr0"
            read -p "Нажмите Enter..." && return 1
        }
        echo "✅ Сеть lxdbr0 создана"
    else
        echo "✓ Сеть lxdbr0 уже существует"
    fi

    # Проверка storage pool
    if ! lxc storage show default >/dev/null 2>&1; then
        echo "⚠️ Storage pool 'default' отсутствует — создаём..."
        lxc storage create default dir || {
            echo "❌ Не удалось создать storage pool"
            read -p "Нажмите Enter..." && exit 1
        }
        echo "✅ Storage pool 'default' создан"
    fi

    # ────────────────────────────────────────────────
    # Исправление профиля default — самый важный блок
    # ────────────────────────────────────────────────
    echo ""
    echo "=== Исправление профиля default ==="

    # Удаляем старый eth0, если существует
    lxc profile device remove default eth0 2>/dev/null || true

    # Добавляем корректный интерфейс с network (ФИКС экранирования)
    if ! lxc profile show default | grep -q "network: lxdbr0"; then
        echo "→ Добавляем сетевой интерфейс eth0 → lxdbr0"
        lxc profile device add default eth0 nic name=eth0 network=lxdbr0 || {
            echo "❌ Не удалось добавить eth0 в профиль default"
            read -p "Нажмите Enter..." && return 1
        }
        echo "✓ Сетевой интерфейс добавлен"
    else
        echo "✓ eth0 уже настроен корректно в профиле"
    fi

    # Проверяем/восстанавливаем root-диск (ФИКС)
    if ! lxc profile show default | grep -q "path: /"; then
        lxc profile device remove default root 2>/dev/null || true
        lxc profile device add default root disk path=/ pool=default || {
            echo "❌ Не удалось настроить root диск"
            read -p "Нажмите Enter..." && return 1
        }
        echo "✓ Root диск настроен"
    else
        echo "✓ Root диск уже настроен"
    fi

    echo "✅ Профиль default исправлен"

    # Прикрепляем сеть ко всем существующим контейнерам
    echo ""
    echo "=== Прикрепление сети к существующим контейнерам ==="
    for cont in $(lxc list -c n --format csv | grep -E "^${CONTAINER_PREFIX}[0-9]+"); do
        echo -n "Проверка сети для $cont... "
        if lxc config device show "$cont" eth0 2>/dev/null | grep -q "network: lxdbr0"; then
            echo "уже подключена"
        else
            lxc network attach lxdbr0 "$cont" eth0 2>/dev/null && echo "OK" || echo "пропуск"
        fi
    done

    # Запрос количества контейнеров
    read -p "Сколько ВСЕГО контейнеров нужно? [1-30, сейчас: $EXISTING_CONTAINERS]: " TOTAL_CONTAINERS
    if ! [[ "$TOTAL_CONTAINERS" =~ ^[0-9]+$ ]] || [ "$TOTAL_CONTAINERS" -lt 1 ] || [ "$TOTAL_CONTAINERS" -gt 30 ]; then
        echo "❌ Некорректное число"
        read -p "Нажмите Enter..." && return
    fi

    if [ "$TOTAL_CONTAINERS" -le "$EXISTING_CONTAINERS" ]; then
        echo "⚠️ Новые контейнеры не требуются"
        read -p "Нажмите Enter..." && return
    fi

    NEW_CONTAINERS=$((TOTAL_CONTAINERS - EXISTING_CONTAINERS))
    echo "Будет создано $NEW_CONTAINERS новых контейнеров (от ${CONTAINER_PREFIX}$((MAX_EXISTING + 1)) до ${CONTAINER_PREFIX}${TOTAL_CONTAINERS})"
    echo ""
    read -p "Подтвердить создание? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { echo "Отменено"; read -p "Enter..."; return; }

    # Создание новых контейнеров (ФИКС синтаксиса)
    echo "=== Создание контейнеров ==="
    for i in $(seq $((MAX_EXISTING + 1)) $TOTAL_CONTAINERS); do
        name="${CONTAINER_PREFIX}${i}"  # ФИКС: убрал local
        echo "Создаю $name..."
        
        lxc launch ubuntu:22.04 "$name" || { echo "❌ Ошибка создания $name"; continue; }

        # Настройки для запуска Docker внутри (ФИКС синтаксиса)
        lxc config set "$name" security.privileged true
        lxc config set "$name" security.nesting true
		#lxc config set "$name" security.syscalls.intercept.sysctl true   # <- добавляем!
        lxc config set "$name" security.syscalls.intercept.mknod true
        #lxc config set "$name" security.syscalls.intercept.setxattr true
        lxc config set "$name" limits.processes 1000

        # Привязка сети
        lxc network attach lxdbr0 "$name" eth0 2>/dev/null || true

        echo "✓ $name настроен"
        sleep 2
    done

    echo "Ожидание запуска контейнеров..."
    sleep 15

    echo ""
    echo "=== Текущий список контейнеров ==="
    lxc list

    # Улучшенная проверка интернета (ФИКС)
    echo ""
    echo "=== Проверка интернета (${CONTAINER_PREFIX}1) ==="
    if lxc info "${CONTAINER_PREFIX}1" >/dev/null 2>&1; then
        if lxc exec "${CONTAINER_PREFIX}1" -- bash -c "ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || curl -s --max-time 5 http://1.1.1.1 >/dev/null 2>&1"; then
            echo "✅ Интернет работает"
        else
            echo "⚠️ Интернет НЕ работает в ${CONTAINER_PREFIX}1"
            echo "   Фикс:"
            echo "   lxc network attach lxdbr0 ${CONTAINER_PREFIX}1 eth0"
            echo "   lxc restart ${CONTAINER_PREFIX}1"
        fi
    else
        echo "⚠️ Контейнер ${CONTAINER_PREFIX}1 не существует"
    fi

    echo ""
    echo "✅ Установка и настройка LXD завершена"
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
    echo "  [3/3] НАСТРОЙКА DOCKER (FIXED)"
    echo "=========================================="

    CONTAINERS=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}")
    [ -z "$CONTAINERS" ] && { echo "❌ Контейнеры не найдены"; read -p "Enter..."; return; }

    for container in $CONTAINERS; do
        echo ""
        echo "--- $container ---"

        # Проверка: Docker есть и драйвер fuse-overlayfs
        DOCKER_OK=$(lxc exec $container -- bash -c '
            if command -v docker >/dev/null 2>&1; then
                DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
                [ "$DRIVER" = "fuse-overlayfs" ] && echo "ok"
            fi
        ')

        if [ "$DOCKER_OK" = "ok" ]; then
            echo "✓ Docker уже установлен и fuse-overlayfs активен, пропускаем"
            continue
        fi

        echo "⏳ Ждем 5 секунд после запуска контейнера..."
        sleep 5

        lxc exec $container -- bash <<'EOF'
set -e

echo "[0/6] ФИКС CONTAINERD (sysctl permission denied)..."

# ФИКС: downgrade containerd если сломанная версия
CURRENT_VER=$(dpkg -l containerd.io 2>/dev/null | awk '/^ii/ {print $3}' || echo "none")
if [[ "$CURRENT_VER" == *"1.7.28-2"* ]] || [[ "$CURRENT_VER" =~ ^1.7\.[0-9]+ ]]; then
    echo "⚠️ Проблемная containerd $CURRENT_VER → downgrade..."
    apt-get update -qq && \
    apt-get install -y containerd.io=1.7.28-1~ubuntu.22.04~jammy --allow-downgrades --no-install-recommends -qq && \
    apt-mark hold containerd.io -qq
    echo "✓ Containerd пофикшен"
fi

echo "[1/6] Проверка nesting..."

# [2/6] Установка fuse-overlayfs с retry
MAX_RETRIES=3
for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Попытка $attempt: установка fuse-overlayfs..."
    if apt-get update -qq && apt-get install -y fuse-overlayfs -qq; then
        echo "✓ fuse-overlayfs установлен"
        break
    else
        echo "⚠ Попытка $attempt не удалась"
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            echo "Ждем 5 секунд перед повтором..."
            sleep 5
        else
            echo "❌ fuse-overlayfs не удалось установить после $MAX_RETRIES попыток"
            exit 1
        fi
    fi
done

# [3/6] Настройка daemon.json
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "storage-driver": "fuse-overlayfs"
}
JSON

# [4/6] Установка Docker, если нет
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

# [5/6] Запуск Docker
systemctl enable docker
systemctl start docker
sleep 3
echo "=== Storage Driver ==="
docker info | grep "Storage Driver"
EOF

        # [6/6] Скачивание образа с retry
        IMAGE="unclecode/crawl4ai:0.7.3"
        MAX_PULL_RETRIES=3
        for attempt in $(seq 1 $MAX_PULL_RETRIES); do
            if lxc exec $container -- docker images | grep -q "unclecode/crawl4ai.*0.7.3"; then
                echo "✓ Образ crawl4ai уже есть"
                break
            else
                echo "📦 Попытка $attempt: скачиваем $IMAGE..."
                if lxc exec $container -- docker pull $IMAGE; then
                    echo "✓ Образ скачан"
                    break
                else
                    echo "⚠ Ошибка при скачивании образа"
                    if [ "$attempt" -lt "$MAX_PULL_RETRIES" ]; then
                        echo "Ждем 5 секунд перед повтором..."
                        sleep 5
                    else
                        echo "❌ Не удалось скачать $IMAGE после $MAX_PULL_RETRIES попыток"
                    fi
                fi
            fi
        done
    done

    echo ""
    echo "✅ Docker + fuse-overlayfs настроены корректно"
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
echo "[$i] Запуск ${CONTAINER_PREFIX}${i}..."
lxc exec ${CONTAINER_PREFIX}${i} -- bash << 'SCRIPT'
mkdir -p /var/log/optimai
echo "[DEBUG] Остановка старых процессов..."
pkill -9 -f 'optimai-cli' 2>/dev/null
sleep 1
echo "[DEBUG] Проверка Docker..."
if ! systemctl is-active docker >/dev/null 2>&1; then
echo "[DEBUG] Запуск Docker..."
systemctl start docker
sleep 3
fi
echo "[DEBUG] Проверка optimai-cli..."
if [ ! -f /usr/local/bin/optimai-cli ]; then
echo "✗ ОШИБКА: optimai-cli не найден!"
exit 1
fi
echo "[DEBUG] Запуск ноды..."
cd /root
nohup /usr/local/bin/optimai-cli node start >> /var/log/optimai/node.log 2>&1 &
sleep 3
if pgrep -f 'optimai-cli' >/dev/null; then
PID=$(pgrep -f 'optimai-cli')
echo "✓ Процесс запущен (PID: $PID)"
else
echo "✗ Ошибка запуска! Лог:"
if [ -f /var/log/optimai/node.log ]; then
tail -20 /var/log/optimai/node.log
else
echo "Лог файл не создан"
fi
exit 1
fi
SCRIPT
echo ""
sleep 2
done
echo "✓ Запуск завершен"
read -p "Нажми Enter для продолжения..."
}


stop_nodes() {
    local max=$(get_max_container)
    echo "Какие остановить? (5, 1-10, Enter=все)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "нет"; continue; }
        
        lxc exec "${CONTAINER_PREFIX}${i}" -- bash -c '
            echo "Останавливаем Docker контейнеры..."
            docker stop optimai_crawl4ai_0_7_3 2>/dev/null || true
            docker rm optimai_crawl4ai_0_7_3 2>/dev/null || true
            docker system prune -f -q 2>/dev/null || true
            
            echo "Останавливаем optimai-cli..."
            pkill -9 -f "optimai-cli" 2>/dev/null || true
            sleep 2
            
            echo "Очистка логов..."
            rm -f /var/log/optimai/node.log
            
            echo "Docker статус: "
            docker ps -q | wc -l | xargs -I {} echo "{} crawl4ai контейнеров осталось"
            echo "Лог очищен"
        '
        echo "✓ остановлено"
    done
    read -p "Нажми Enter..."
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
            status=$(lxc exec ${CONTAINER_PREFIX}${i} -- pgrep -f "optimai-cli" >/dev/null 2>&1 && echo "РАБОТАЕТ" || echo "ОСТАНОВЛЕНА")
            echo "${CONTAINER_PREFIX}${i}: $status"
        fi
    done
    read -p "Нажми Enter..."
}

# === Главное меню ===
while true; do
    clear
    echo "=========================================="
    echo " LXD + DOCKER + OPTIMAI MANAGER"
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
