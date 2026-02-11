#!/bin/bash
set -e

# Global variable for container prefix
CONTAINER_PREFIX="node"
# File for credentials storage
CREDENTIALS_FILE="/root/.optimai_credentials"

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Please run the script with sudo: sudo bash lxd_optimai_manager.sh"
    exit 1
fi

# ============================================
# BLOCK 1: LXD INSTALLATION AND SETUP
# ============================================

update_system() {
    echo ""
    echo "=========================================="
    echo " [1/3] SYSTEM UPDATE"
    echo "=========================================="
    echo ""
    echo "=== VPS Status Check ==="
    echo "Hostname: $(hostname)"
    echo "OS: $(lsb_release -d | cut -f2)"
    echo "Kernel: $(uname -r)"
    echo "CPU cores: $(nproc)"
    echo "RAM: $(free -h | grep Mem | awk '{print $2}')"
    echo "Disk: $(df -h / | tail -1 | awk '{print $2}')"
    echo ""
    echo "=== Updating packages ==="
    apt update && apt upgrade -y
    echo ""
    echo "=== Installing dependencies ==="
    apt install -y snapd curl ca-certificates gnupg
    echo ""
    echo "✅ System updated"
    read -p "Press Enter to continue..."
}

install_lxd() {
    echo ""
    echo "=========================================="
    echo " [2/3] LXD INSTALLATION AND PREPARATION"
    echo "=========================================="

    # --- STEP 0: HOST PREPARATION (VPS) ---
    echo "=== Preparing host system ==="
    # Load kernel modules on host, otherwise overlay2 in container won't work
    modprobe overlay
    modprobe br_netfilter
    
    # Add to host autostart
    echo "overlay" > /etc/modules-load.d/lxd-docker.conf
    echo "br_netfilter" >> /etc/modules-load.d/lxd-docker.conf
    
    # Allow traffic forwarding (required for Docker network)
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "✅ Host prepared (modules loaded)"

    # --- STEP 1: CHECK EXISTING CONTAINERS ---
    EXISTING_CONTAINERS=$(lxc list -c n --format csv 2>/dev/null | grep -E "^${CONTAINER_PREFIX}[0-9]+" | wc -l)
    if [ "$EXISTING_CONTAINERS" -gt 0 ]; then
        MAX_EXISTING=$(lxc list -c n --format csv | grep -E "^${CONTAINER_PREFIX}[0-9]+" | sed "s/${CONTAINER_PREFIX}//" | sort -n | tail -1)
        echo "Containers found: $EXISTING_CONTAINERS, Max ID: ${CONTAINER_PREFIX}${MAX_EXISTING}"
    else
        EXISTING_CONTAINERS=0
        MAX_EXISTING=0
    fi

    # --- STEP 2: INSTALL LXD ---
    if ! command -v lxc >/dev/null 2>&1; then
        echo "=== Installing LXD via snap ==="
        snap install lxd --channel=5.21/stable
        sleep 5
        lxd init --auto
    else
        echo "✓ LXD is already installed"
    fi

    # --- STEP 3: NETWORK AND STORAGE SETUP ---
    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        lxc network create lxdbr0 ipv4.nat=true ipv6.address=none
    fi

    if ! lxc storage show default >/dev/null 2>&1; then
        lxc storage create default dir
    fi

    # Default profile fix
    lxc profile device remove default eth0 2>/dev/null || true
    lxc profile device add default eth0 nic name=eth0 network=lxdbr0 2>/dev/null || true
    lxc profile device remove default root 2>/dev/null || true
    lxc profile device add default root disk path=/ pool=default 2>/dev/null || true

    # --- STEP 4: CREATE CONTAINERS ---
    read -p "How many TOTAL containers are needed? [1-30, currently: $EXISTING_CONTAINERS]: " TOTAL_CONTAINERS
    if ! [[ "$TOTAL_CONTAINERS" =~ ^[0-9]+$ ]] || [ "$TOTAL_CONTAINERS" -le "$EXISTING_CONTAINERS" ]; then
        echo "⚠️ No new containers needed or invalid number entered"
        read -p "Press Enter..." && return
    fi

    for i in $(seq $((MAX_EXISTING + 1)) $TOTAL_CONTAINERS); do
        name="${CONTAINER_PREFIX}${i}"
        echo "🚀 Creating and configuring $name..."
        
        lxc launch ubuntu:22.04 "$name" || continue

        # ══════════════════════════════════════════════════
        # ENHANCED SETTINGS FOR DOCKER (OVERLAY2 FIX)
        # ══════════════════════════════════════════════════
        
        # 1. Privileges and nesting
        lxc config set "$name" security.privileged true
        lxc config set "$name" security.nesting true
        
        # 2. Kernel modules passthrough
        lxc config set "$name" linux.kernel_modules overlay,br_netfilter,ip_tables,iptable_nat,xt_conntrack
        
        # 3. AppArmor and mounting (Critical for overlay2)
        lxc config set "$name" raw.lxc "lxc.apparmor.profile=unconfined
lxc.mount.auto=proc:rw sys:rw cgroup:rw
lxc.cgroup.devices.allow=a
lxc.cap.drop="

        # 4. Limits
        lxc config set "$name" limits.processes 2500
        
        # Restart to apply raw.lxc immediately
        lxc restart "$name"
        echo "✓ $name is ready"
        sleep 1
    done

    echo ""
    echo "✅ All new containers created and configured with Docker/Overlay2 support"
    read -p "Press Enter to continue..."
}

setup_swap() {
    echo ""
    echo "=========================================="
    echo " SWAP FILE CONFIGURATION"
    echo "=========================================="

    echo "=== Current SWAP ==="
    CURRENT_SWAP=$(swapon --show --noheadings)
    if [ -n "$CURRENT_SWAP" ]; then
        swapon --show
        SWAP_FILE=$(swapon --show --noheadings | awk '{print $1}' | head -1)
        echo "1) Delete and create new   2) Keep current"
        read -p "[1-2]: " swap_choice
        if [ "$swap_choice" = "2" ]; then
            read -p "Press Enter..." && return
        fi
        swapoff "$SWAP_FILE"
        rm -f "$SWAP_FILE"
        sed -i "\|$SWAP_FILE|d" /etc/fstab
    fi

    read -p "SWAP size in GB [1-128]: " SWAP_SIZE
    if ! [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE" -lt 1 ] || [ "$SWAP_SIZE" -gt 128 ]; then
        echo "❌ Invalid size"
        read -p "Press Enter..." && return
    fi

    SWAP_FILE="/swapfile"
    echo "Creating ${SWAP_SIZE}GB..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1G count=$SWAP_SIZE status=progress
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

    echo "✓ SWAP is ready"
    swapon --show
    free -h | grep -E "Mem|Swap"
    read -p "Press Enter..."
}

setup_docker() {
    echo ""
    echo "=========================================="
    echo "  [3/3] DOCKER SETUP (ULTRA-FIXED)"
    echo "=========================================="

    CONTAINERS=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}")
    [ -z "$CONTAINERS" ] && { echo "❌ No containers found"; read -p "Enter..."; return; }

    for container in $CONTAINERS; do
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║  Configuring: $container"
        echo "╚══════════════════════════════════════╝"

        # Check: Docker presence and overlay2 driver
        DOCKER_OK=$(lxc exec $container -- bash -c '
            if command -v docker >/dev/null 2>&1; then
                DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
                [ "$DRIVER" = "overlay2" ] && echo "ok"
            fi
        ')

        if [ "$DOCKER_OK" = "ok" ]; then
            echo "✓ Docker already installed and overlay2 active, skipping"
            continue
        fi

        echo "⏳ Waiting 5 seconds after container startup..."
        sleep 5

        lxc exec $container -- bash <<'EOF'
set -e

echo ""
echo "════════════════════════════════════════"
echo " INSTALLING DOCKER WITH OVERLAY2 DRIVER"
echo "════════════════════════════════════════"
echo ""

# [1/5] Remove old Docker if exists
echo "[1/5] Cleaning up old Docker versions..."
systemctl stop docker 2>/dev/null || true
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
rm -rf /var/lib/docker /etc/docker

# [2/5] Install Docker from official source
echo "[2/5] Installing fresh Docker..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm /tmp/get-docker.sh

# [3/5] Configure daemon.json for overlay2
echo "[3/5] Configuring overlay2 driver..."
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

# [4/5] Start Docker
echo "[4/5] Starting Docker..."
systemctl daemon-reload
systemctl enable docker
systemctl restart docker
sleep 5

# Driver check
echo ""
echo "════════════════════════════════════════"
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "ERROR")
if [ "$DRIVER" = "overlay2" ]; then
    echo "✅ Storage Driver: overlay2 (OK)"
else
    echo "❌ Storage Driver: $DRIVER (NOT OK!)"
    echo ""
    echo "Full Info:"
    docker info
    exit 1
fi
echo "════════════════════════════════════════"
echo ""

# [5/5] Pulling crawl4ai image
echo "[5/5] Downloading crawl4ai image..."
IMAGE="unclecode/crawl4ai:0.7.3"
MAX_RETRIES=3

for attempt in $(seq 1 $MAX_RETRIES); do
    if docker images | grep -q "unclecode/crawl4ai.*0.7.3"; then
        echo "✅ crawl4ai image already present"
        break
    else
        echo "📦 Attempt $attempt: pulling $IMAGE..."
        if timeout 300 docker pull $IMAGE; then
            echo "✅ Image pulled successfully"
            break
        else
            echo "⚠ Error during pull"
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                echo "Waiting 10 seconds before retry..."
                sleep 10
            else
                echo "❌ Failed to download after $MAX_RETRIES attempts"
                exit 1
            fi
        fi
    fi
done

echo ""
echo "✅ Docker configured correctly!"
docker --version
docker info | grep -E "Storage Driver|Logging Driver"
EOF

        if [ $? -eq 0 ]; then
            echo "✅ $container is ready"
        else
            echo "❌ Error setting up $container"
        fi
        
        sleep 2
    done

    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  ✅ Docker + overlay2 configured!    ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Press Enter..."
}

# ============================================
# BLOCK 2: OPTIMAI INSTALLATION AND LOGIN
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
        echo "ERROR: number or range required"
        return 1
    fi
    if [ "$start" -lt 1 ] || [ "$start" -gt "$max" ] || [ "$end" -lt 1 ] || [ "$end" -gt "$max" ] || [ "$start" -gt "$end" ]; then
        echo "ERROR: invalid range"
        return 1
    fi
    echo "$start $end"
    return 0
}

install_optimai() {
    echo ""
    echo "=========================================="
    echo " INSTALLING OPTIMAI CLI"
    echo "=========================================="
    local max=$(get_max_container)
    echo "Which containers? (e.g. 5, 1-10, Enter for all 1-$max)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "no"; continue; }

        if lxc exec ${CONTAINER_PREFIX}${i} -- test -f /usr/local/bin/optimai-cli 2>/dev/null; then
            echo "already installed"
            continue
        fi

        echo "installing..."
        lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
            curl -L https://optimai.network/download/cli-node/linux -o /tmp/optimai-cli &&
            chmod +x /tmp/optimai-cli &&
            mv /tmp/optimai-cli /usr/local/bin/optimai-cli
        "
    done
    echo ""
    echo "Installation complete"
    read -p "Press Enter..."
}

update_optimai() {
    echo ""
    echo "=========================================="
    echo " UPDATING OPTIMAI CLI"
    echo "=========================================="
    local max=$(get_max_container)
    echo "Where to update? (5, 1-10, Enter for all)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "no"; continue; }
        lxc exec ${CONTAINER_PREFIX}${i} -- /usr/local/bin/optimai-cli update 2>/dev/null && echo "OK" || echo "error"
    done
    echo ""
    echo "Update complete"
    read -p "Press Enter..."
}

login_optimai() {
    echo ""
    echo "=========================================="
    echo " OPTIMAI LOGIN"
    echo "=========================================="

    # Get login/password
    if [ -f "$CREDENTIALS_FILE" ]; then
        echo "Saved credentials found. Choose action: 1 — use saved, 2 — enter new."
        read -p "[1-2]: " ch
        if [ "$ch" = "1" ]; then
            source "$CREDENTIALS_FILE"
        else
            read -p "Email: " OPTIMAI_LOGIN
            read -sp "Password: " OPTIMAI_PASSWORD; echo
            echo "OPTIMAI_LOGIN=\"$OPTIMAI_LOGIN\"" > "$CREDENTIALS_FILE"
            echo "OPTIMAI_PASSWORD=\"$OPTIMAI_PASSWORD\"" >> "$CREDENTIALS_FILE"
            chmod 600 "$CREDENTIALS_FILE"
        fi
    else
        read -p "Email: " OPTIMAI_LOGIN
        read -sp "Password: " OPTIMAI_PASSWORD; echo
        echo "OPTIMAI_LOGIN=\"$OPTIMAI_LOGIN\"" > "$CREDENTIALS_FILE"
        echo "OPTIMAI_PASSWORD=\"$OPTIMAI_PASSWORD\"" >> "$CREDENTIALS_FILE"
        chmod 600 "$CREDENTIALS_FILE"
    fi

    echo ""
    echo "In which containers? (e.g. 5, 1-10, Enter for all)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Press Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        if ! lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$"; then
            echo "no"
            continue
        fi

        lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
            [ -f /usr/local/bin/optimai-cli ] || { echo 'CLI not installed'; exit 1; }
            command -v expect >/dev/null || { apt-get update -qq && apt-get install -y expect -qq >/dev/null; }
            expect <<'EOF'
set timeout 60
spawn /usr/local/bin/optimai-cli auth login
expect {
    \"Already logged in\" {
        puts \"✓ Already logged in\"
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
                    puts \"✓ Login successful\"
                    exit 0
                }
                \"Invalid\" {
                    puts \"✗ Invalid login or password\"
                    exit 1
                }
                timeout {
                    puts \"✗ Timeout after password\"
                    exit 1
                }
            }
        }
        timeout {
            puts \"✗ Password field not found\"
            exit 1
        }
    }
    timeout {
        puts \"✗ Email field not found\"
        exit 1
    }
}
EOF
        " && echo "OK" || echo "FAIL"
        sleep 1
    done

    echo ""
    echo "Login finished"
    read -p "Press Enter..."
}

# ============================================
# BLOCK 3: NODE MANAGEMENT
# ============================================

start_nodes() {
    local max=$(get_max_container)
    echo "Which nodes to start? (e.g. 5, 1-10 or Enter for all 1-$max)"
    read -r range
    result=$(parse_range "$range")
    if [ $? -ne 0 ]; then
        echo "✗ $result"
        read -p "Press Enter to continue..."
        return
    fi
    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)
    
    if [ "$start" -eq "$end" ]; then
        echo "Starting ${CONTAINER_PREFIX}${start}..."
    else
        echo "Starting nodes from ${CONTAINER_PREFIX}${start} to ${CONTAINER_PREFIX}${end}..."
    fi
    
    for i in $(seq $start $end); do
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║  Starting ${CONTAINER_PREFIX}${i}"
        echo "╚══════════════════════════════════════╝"
        
        lxc exec ${CONTAINER_PREFIX}${i} -- bash << 'SCRIPT'
set -e

mkdir -p /var/log/optimai

echo "[1/6] Stopping old processes..."
pkill -9 -f 'optimai-cli' 2>/dev/null || true
docker stop optimai_crawl4ai_0_7_3 2>/dev/null || true
docker rm optimai_crawl4ai_0_7_3 2>/dev/null || true
sleep 2

echo "[2/6] Checking Docker..."
if ! systemctl is-active docker >/dev/null 2>&1; then
    echo "→ Starting Docker..."
    systemctl start docker
    sleep 5
fi

echo "[3/6] Checking storage driver..."
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
if [ "$DRIVER" != "overlay2" ]; then
    echo "❌ CRITICAL: Docker uses '$DRIVER' instead of overlay2!"
    echo "Run item 3 (Setup Docker) from main menu"
    exit 1
fi
echo "✓ Storage Driver: overlay2"

echo "[4/6] Checking optimai-cli..."
if [ ! -f /usr/local/bin/optimai-cli ]; then
    echo "✗ ERROR: optimai-cli not found!"
    exit 1
fi

echo "[5/6] Starting node..."
cd /root
rm -f /var/log/optimai/node.log
nohup /usr/local/bin/optimai-cli node start >> /var/log/optimai/node.log 2>&1 &
sleep 5

echo "[6/6] Startup check..."
if pgrep -f 'optimai-cli' >/dev/null; then
    PID=$(pgrep -f 'optimai-cli')
    echo "✅ Process started (PID: $PID)"
    echo ""
    echo "Log first lines:"
    head -20 /var/log/optimai/node.log 2>/dev/null || echo "Log is empty"
else
    echo "❌ Startup failed!"
    echo ""
    echo "Log content:"
    if [ -f /var/log/optimai/node.log ]; then
        cat /var/log/optimai/node.log
    else
        echo "Log file not created"
    fi
    exit 1
fi
SCRIPT
        
        if [ $? -eq 0 ]; then
            echo "✅ ${CONTAINER_PREFIX}${i} started"
        else
            echo "❌ Startup error in ${CONTAINER_PREFIX}${i}"
        fi
        
        sleep 2
    done
    
    echo ""
    echo "✅ Startup complete"
    read -p "Press Enter to continue..."
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
# FUNCTION: Delete all LXD containers
# ============================================
delete_all_containers() {
    CONTAINERS=$(lxc list -c n --format csv | grep "^${CONTAINER_PREFIX}")
    if [ -z "$CONTAINERS" ]; then
        echo "No containers to delete"
        read -p "Press Enter..." 
        return
    fi

    echo "Deleting all containers (${CONTAINER_PREFIX}*):"
    echo "$CONTAINERS"
    read -p "Confirm deletion? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        read -p "Enter..." 
        return
    fi

    for c in $CONTAINERS; do
        echo "Stopping $c..."
        lxc stop "$c" --force 2>/dev/null || true
        echo "Deleting $c..."
        lxc delete "$c" 2>/dev/null || echo "Error deleting $c"
    done

    echo "✅ All containers deleted"
    read -p "Press Enter..."
}


view_logs() {
    local max=$(get_max_container)
    echo "Container number (1-$max):"
    read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$max" ] && { echo "Invalid"; read -p "Enter..."; return; }

    echo "=== Logs of ${CONTAINER_PREFIX}${num} ==="
    lxc exec ${CONTAINER_PREFIX}${num} -- bash -c '
        if [ -f /var/log/optimai/node.log ]; then
            tail -50 /var/log/optimai/node.log
        else
            echo "No logs found"
            ps aux | grep optimai | grep -v grep || echo "Process not running"
        fi
    '
    echo ""
    read -p "Follow in real-time? (y/n): " follow
    [ "$follow" = "y" ] && lxc exec ${CONTAINER_PREFIX}${num} -- tail -f /var/log/optimai/node.log
}

check_status() {
    echo "=== NODE STATUS ==="
    for i in $(seq 1 $(get_max_container)); do
        if lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$"; then
            status=$(lxc exec ${CONTAINER_PREFIX}${i} -- pgrep -f "optimai-cli" >/dev/null 2>&1 && echo "🟢 RUNNING" || echo "🔴 STOPPED")
            
            # Extra check for Docker driver
            driver=$(lxc exec ${CONTAINER_PREFIX}${i} -- docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
            
            echo "${CONTAINER_PREFIX}${i}: $status | Docker: $driver"
        fi
    done
    read -p "Press Enter..."
}

# === Main Menu ===
while true; do
    clear
    echo "=========================================="
    echo " LXD + DOCKER + OPTIMAI MANAGER v2.0"
    echo "=========================================="
    echo ""

    echo "=== INSTALLATION AND SETUP ==="
    echo "1) Update System"
    echo "2) Install LXD and Create Containers"
    echo "3) Setup Docker inside Containers"
    echo "4) Install OptimAI CLI in Containers"
    echo ""

    echo "=== MANAGE OPTIMAI NODES ==="
    echo "5) Login OptimAI in Containers"
    echo "6) Start Nodes"
    echo "7) Stop Nodes"
    echo "8) View Logs"
    echo "9) Check Status of All Nodes"
    echo ""

    echo "=== MISCELLANEOUS ==="
    echo "10) Configure SWAP File"
    echo "11) Update OptimAI CLI"
    echo "12) Delete All LXD Containers"
    echo "13) Exit"
    echo "=========================================="

    read -p "Choose option [1-13]: " choice
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
        13) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid choice"; sleep 2 ;;
    esac
done
