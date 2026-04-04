#!/bin/bash
# ============================================
# OPTIMAI WATCHDOG
# Проверяет ноды → запускает упавшие → повтор
# ============================================

CONTAINER_PREFIX="node"
RESTART_INTERVAL=120   # секунд между запусками нод
CHECK_INTERVAL=300     # секунд между полными циклами проверки
LOG_STALE_SECONDS=600  # секунд без обновления лога = нода зависла
LOG_FILE="/var/log/optimai_watchdog.log"
LOCK_FILE="/tmp/optimai_watchdog.lock"

# ── Один экземпляр ──────────────────────────
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
    echo "⚠️  Watchdog уже запущен (PID $(cat "$LOCK_FILE"))"
    exit 1
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; echo "$(date "+%Y-%m-%d %H:%M:%S") [WATCHDOG] Остановлен" >> "$LOG_FILE"' EXIT

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") $1" | tee -a "$LOG_FILE"
}

# ── Получить максимальный номер контейнера ──
get_max_container() {
    local max_num
    max_num=$(lxc list -c n --format csv 2>/dev/null \
        | grep "^${CONTAINER_PREFIX}[0-9]" \
        | sed "s/${CONTAINER_PREFIX}//" \
        | sort -n | tail -1)
    [ -z "$max_num" ] && echo "0" || echo "$max_num"
}

# ── Проверить, работает ли нода ─────────────
is_node_running() {
    local container=$1

    # 1. Проверка процесса — ловим и optimai-cli и optimai_cli_core
    local proc
    proc=$(lxc exec "$container" -- bash -c '
        pgrep -f "optimai.cli" >/dev/null 2>&1 && echo "yes" || echo "no"
    ' 2>/dev/null || echo "no")

    if [ "$proc" != "yes" ]; then
        log "[DEAD] $container — процесс не найден"
        return 1
    fi

    # 2. Проверка Docker контейнера
    local docker_ok
    docker_ok=$(lxc exec "$container" -- bash -c '
        docker ps 2>/dev/null | grep -q "optimai_crawl4ai" && echo "yes" || echo "no"
    ' 2>/dev/null || echo "no")

    if [ "$docker_ok" != "yes" ]; then
        log "[DEAD] $container — Docker контейнер не запущен"
        return 1
    fi

    # 3. Проверка свежести лога со стороны ХОСТА
    local log_path="/var/snap/lxd/common/lxd/storage-pools/default/containers/${container}/rootfs/var/log/optimai/node.log"

    if [ ! -f "$log_path" ]; then
        log "[DEAD] $container — лог не найден"
        return 1
    fi

    local last_mod now age
    last_mod=$(stat -c %Y "$log_path" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - last_mod ))

    if [ "$age" -gt "$LOG_STALE_SECONDS" ]; then
        log "[HANG] $container — лог не обновлялся ${age} сек, нода зависла"
        return 1
    fi

    # 4. Проверка на ошибки краша в логе
    local errors
    errors=$(lxc exec "$container" -- bash -c '
        f=/var/log/optimai/node.log
        [ -f "$f" ] && tail -20 "$f" | grep -c "Node service stopped\|FileNotFoundError\|CRITICAL" 2>/dev/null || echo 0
    ' 2>/dev/null || echo 0)

    if [ "$errors" -gt 0 ]; then
        log "[CRASH] $container — в логе обнаружены ошибки краша"
        return 1
    fi

    return 0
}

# ── Запустить ноду и ждать пока поднимется ──
start_node() {
    local container=$1
    log "[START] Запускаю $container..."

    lxc exec "$container" -- bash << 'SCRIPT'
set -e

mkdir -p /var/log/optimai
mkdir -p /root/.config/optimai-cli
mkdir -p /root/.local/state/optimai-cli

echo "[1/5] Остановка старых процессов..."
pkill -9 -f 'optimai-cli' 2>/dev/null || true
pkill -9 -f 'optimai_cli_core' 2>/dev/null || true
sleep 2
docker stop optimai_crawl4ai_0_7_3 2>/dev/null || true
docker rm   optimai_crawl4ai_0_7_3 2>/dev/null || true
rm -f /root/.local/state/optimai-cli/node_cli.lock 2>/dev/null || true
sleep 3

echo "[2/5] Проверка Docker..."
if ! systemctl is-active docker >/dev/null 2>&1; then
    systemctl start docker
    for i in $(seq 1 15); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
fi

echo "[3/5] Проверка storage driver..."
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
if [ "$DRIVER" != "overlay2" ]; then
    echo "❌ Docker driver: $DRIVER (нужен overlay2)"
    exit 1
fi

echo "[4/5] Проверка optimai-cli..."
if [ ! -f /usr/local/bin/optimai-cli ]; then
    echo "❌ optimai-cli не найден!"
    exit 1
fi

echo "[5/5] Запуск ноды..."
cd /root
rm -f /var/log/optimai/node.log
setsid /usr/local/bin/optimai-cli node start >> /var/log/optimai/node.log 2>&1 &
disown

# Ждём появления признаков жизни — максимум 60 сек
echo "⏳ Ожидание запуска (макс 60 сек)..."
READY=false
for i in $(seq 1 60); do
    sleep 1

    # Показываем последнюю строку лога
    LAST=$(tail -1 /var/log/optimai/node.log 2>/dev/null || echo "")
    [ -n "$LAST" ] && echo "  [$i] $LAST"

    # Проверяем процесс + докер + признак успеха в логе
    PROC=$(pgrep -f "optimai.cli" >/dev/null 2>&1 && echo "yes" || echo "no")
    DOCKER=$(docker ps 2>/dev/null | grep -q "optimai_crawl4ai" && echo "yes" || echo "no")
    LOG_OK=$(grep -q "heartbeat sent\|crawler service ready\|Starting services" /var/log/optimai/node.log 2>/dev/null && echo "yes" || echo "no")

    if [ "$PROC" = "yes" ] && [ "$DOCKER" = "yes" ] && [ "$LOG_OK" = "yes" ]; then
        READY=true
        break
    fi

    # Если краш — выходим раньше
    if grep -q "Node service stopped\|FileNotFoundError\|CRITICAL" /var/log/optimai/node.log 2>/dev/null; then
        echo "❌ Обнаружен краш в логе"
        break
    fi
done

if [ "$READY" = "true" ]; then
    echo "✅ Нода запущена успешно"
    exit 0
else
    echo "❌ Нода не запустилась, последние строки лога:"
    tail -10 /var/log/optimai/node.log 2>/dev/null || echo "(пусто)"
    exit 1
fi
SCRIPT

    return $?
}

# ── Ротация логов нод (обрезаем но сохраняем mtime) ──
rotate_logs() {
    local max=$1
    local lxc_list=$2
    for i in $(seq 1 "$max"); do
        container="${CONTAINER_PREFIX}${i}"
        echo "$lxc_list" | grep -q "^${container}$" || continue
        local log_path="/var/snap/lxd/common/lxd/storage-pools/default/containers/${container}/rootfs/var/log/optimai/node.log"
        [ -f "$log_path" ] || continue
        local orig_mtime
        orig_mtime=$(stat -c %y "$log_path" 2>/dev/null)
        tail -100 "$log_path" > "${log_path}.tmp" && mv "${log_path}.tmp" "$log_path"
        touch -d "$orig_mtime" "$log_path" 2>/dev/null
    done
}


log "[WATCHDOG] Запущен (PID $$)"

while true; do

    MAX=$(get_max_container)
    if [ "$MAX" -eq 0 ]; then
        log "[WATCHDOG] Контейнеры не найдены, жду 60 сек..."
        sleep 60
        continue
    fi

    log "[WATCHDOG] ── Проверка нод (1-$MAX) ──"

    # ── Шаг 1: Проход по всем нодам, сбор упавших ──
    LXC_LIST=$(lxc list -c n --format csv 2>/dev/null)
    DEAD_NODES=()

    for i in $(seq 1 "$MAX"); do
        container="${CONTAINER_PREFIX}${i}"
        if ! echo "$LXC_LIST" | grep -q "^${container}$"; then
            continue
        fi

        if is_node_running "$container"; then
            log "[OK]   $container работает"
        else
            log "[DEAD] $container → добавляю в очередь перезапуска"
            DEAD_NODES+=("$container")
        fi
    done

    # ── Шаг 2: Запуск упавших по очереди с интервалом ──
    if [ ${#DEAD_NODES[@]} -eq 0 ]; then
        log "[WATCHDOG] Все ноды работают ✅"
    else
        log "[WATCHDOG] Перезапускаю: ${#DEAD_NODES[@]} нод → ${DEAD_NODES[*]}"

        for idx in "${!DEAD_NODES[@]}"; do
            container="${DEAD_NODES[$idx]}"

            start_node "$container" \
                && log "[OK]   $container успешно запущен" \
                || log "[FAIL] $container не удалось запустить"

            # Пауза 5 сек перед следующим
            if [ $idx -lt $(( ${#DEAD_NODES[@]} - 1 )) ]; then
                log "[WATCHDOG] Пауза 5 сек перед следующим..."
                sleep 5
            fi
        done

        # ── Шаг 3: Повторная проверка всего списка ──
        log "[WATCHDOG] ── Повторная проверка после перезапусков ──"
        LXC_LIST=$(lxc list -c n --format csv 2>/dev/null)
        for i in $(seq 1 "$MAX"); do
            container="${CONTAINER_PREFIX}${i}"
            echo "$LXC_LIST" | grep -q "^${container}$" || continue
            if is_node_running "$container"; then
                log "[OK]   $container работает"
            else
                log "[FAIL] $container всё ещё не работает"
            fi
        done
    fi

    rotate_logs "$MAX" "$LXC_LIST"
    log "[WATCHDOG] Следующая проверка через ${CHECK_INTERVAL} сек..."
    sleep "$CHECK_INTERVAL"

done
