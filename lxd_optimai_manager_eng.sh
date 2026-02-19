#!/bin/bash
set -e

# Global variable for container prefix
CONTAINER_PREFIX="node"
# File for storing credentials
CREDENTIALS_FILE="/root/.optimai_credentials"

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Run the script with sudo: sudo bash lxd_optimai_manager.sh"
    exit 1
fi

# Handle Ctrl+C — exit without error
trap 'echo ""; echo "⛔ Interrupted by user (Ctrl+C)"; exit 0' INT

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
    apt install -y --no-install-recommends snapd curl ca-certificates gnupg
    echo ""
    echo "✅ System updated"
    read -p "Press Enter to continue..."
}

install_lxd() {
    echo ""
    echo "=========================================="
    echo " [2/3] LXD INSTALLATION AND SETUP"
    echo "=========================================="

    echo "=== Preparing host system ==="
    modprobe overlay
    modprobe br_netfilter
    echo "overlay" > /etc/modules-load.d/lxd-docker.conf
    echo "br_netfilter" >> /etc/modules-load.d/lxd-docker.conf
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "✅ Host prepared (modules loaded)"

    EXISTING_CONTAINERS=$(lxc list -c n --format csv 2>/dev/null | grep -E "^${CONTAINER_PREFIX}[0-9]+" | wc -l)
    if [ "$EXISTING_CONTAINERS" -gt 0 ]; then
        MAX_EXISTING=$(lxc list -c n --format csv | grep -E "^${CONTAINER_PREFIX}[0-9]+" | sed "s/${CONTAINER_PREFIX}//" | sort -n | tail -1)
        echo "Found containers: $EXISTING_CONTAINERS, Max ID: ${CONTAINER_PREFIX}${MAX_EXISTING}"
    else
        EXISTING_CONTAINERS=0
        MAX_EXISTING=0
    fi

    if ! command -v lxc >/dev/null 2>&1; then
        echo "=== Installing LXD via snap ==="
        snap install lxd --channel=5.21/stable
        sleep 5
        lxd init --auto
    else
        echo "✓ LXD already installed"
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

    read -p "How many TOTAL containers needed? [1-30, current: $EXISTING_CONTAINERS]: " TOTAL_CONTAINERS
    if ! [[ "$TOTAL_CONTAINERS" =~ ^[0-9]+$ ]] || [ "$TOTAL_CONTAINERS" -le "$EXISTING_CONTAINERS" ]; then
        echo "⚠️ No new containers needed or invalid number"
        read -p "Press Enter..." && return
    fi

    for i in $(seq $((MAX_EXISTING + 1)) $TOTAL_CONTAINERS); do
        name="${CONTAINER_PREFIX}${i}"
        echo "🚀 Creating and configuring $name..."
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
        echo "✓ $name ready to work"
        sleep 1
    done

    echo ""
    echo "✅ All new containers created and configured with Docker/Overlay2 support"
    read -p "Press Enter to continue..."
}

setup_swap() {
    echo ""
    echo "=========================================="
    echo " SWAP FILE SETUP"
    echo "=========================================="

    echo "=== Current SWAP ==="
    CURRENT_SWAP=$(swapon --show --noheadings)
    if [ -n "$CURRENT_SWAP" ]; then
        swapon --show
        SWAP_FILE=$(swapon --show --noheadings | awk '{print $1}' | head -1)
        echo "1) Delete and create new   2) Keep"
        read -p "[1-2]: " swap_choice
        if [ "$swap_choice" = "2" ]; then
            read -p "Press Enter..." && return
        fi
        swapoff "$SWAP_FILE"
        rm -f "$SWAP_FILE"
        sed -i "\\|$SWAP_FILE|d" /etc/fstab
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
    echo "✓ SWAP ready"
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
    [ -z "$CONTAINERS" ] && { echo "❌ Containers not found"; read -p "Enter..."; return; }

    for container in $CONTAINERS; do
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║  Setting up: $container"
        echo "╚══════════════════════════════════════╝"

        DOCKER_OK=$(lxc exec $container -- bash -c '
            if command -v docker >/dev/null 2>&1; then
                DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
                [ "$DRIVER" = "overlay2" ] && echo "ok"
            fi
        ' 2>/dev/null || echo "error")

        if [ "$DOCKER_OK" = "ok" ]; then
            echo "✓ Docker already installed and overlay2 active, skipping"
            continue
        fi

        echo "⏳ Waiting 2 seconds after container start..."
        sleep 2

        ATTEMPT=0
        SUCCESS=false
        set +e  # temporarily disable set -e for retry logic
        while [ $ATTEMPT -lt 2 ]; do
            ATTEMPT=$((ATTEMPT + 1))
            [ $ATTEMPT -gt 1 ] && echo "🔄 Attempt $ATTEMPT: restarting container and trying again..." && lxc restart "$container" && sleep 3

            lxc exec $container -- bash <<'EOF'
set -e

echo ""
echo "════════════════════════════════════════"
echo " DOCKER INSTALLATION WITH OVERLAY2 DRIVER"
echo "════════════════════════════════════════"
echo ""

echo "[1/4] Cleaning old Docker versions..."
systemctl stop docker 2>/dev/null || true
apt-get remove -y docker docker-engine docker.io containerd runc \\
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
rm -rf /var/lib/docker /etc/docker
# Remove docker repository to avoid install script warnings
rm -f /etc/apt/sources.list.d/docker.list
rm -f /usr/bin/docker /usr/local/bin/docker

echo "[2/4] Installing fresh Docker..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm /tmp/get-docker.sh

echo "[3/4] Configuring overlay2 driver..."
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

echo "[4/4] Starting Docker..."
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

echo "  → Waiting for Docker readiness..."
for i in $(seq 1 15); do
    docker info >/dev/null 2>&1 && break
    sleep 1
done

echo ""
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "ERROR")
if [ "$DRIVER" = "overlay2" ]; then
    echo "✅ Storage Driver: overlay2 (OK)"
else
    echo "❌ Storage Driver: $DRIVER (NOT OK!)"
    docker info
    exit 1
fi

echo ""
echo "✅ Docker configured correctly!"
docker --version
docker info | grep -E "Storage Driver|Logging Driver"
EOF

            if [ $? -eq 0 ]; then
                SUCCESS=true
                break
            fi
        done

        if [ "$SUCCESS" = "true" ]; then
            echo "✅ $container ready"
        else
            echo "❌ $container setup failed after 2 attempts, skipping"
        fi
        set -e  # re-enable set -e
        sleep 2
    done

    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  ✅ Docker + overlay2 configured!     ║"
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
        echo "ERROR: number or range expected"
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
    echo " OPTIMAI CLI + DOCKER IMAGE INSTALLATION"
    echo "=========================================="

    local max=$(get_max_container)
    echo "Which containers? (5, 1-10, Enter=all 1-$max)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    # ──────────────────────────────────────────────────────
    # STEP 1: Automatic local registry setup
    # Image downloaded ONCE to host, other containers pull locally without internet
    # ──────────────────────────────────────────────────────
    echo ""
    echo "=== [1/3] Preparing local Docker Registry ==="

    BRIDGE_IP=$(ip addr show lxdbr0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    USE_LOCAL=false

    if [ -z "$BRIDGE_IP" ]; then
        echo "  ⚠️  lxdbr0 not found, image will be downloaded from internet"
    else
        # Install Docker on host if missing
        if ! command -v docker >/dev/null 2>&1; then
            echo "  → Installing Docker on host..."
            curl -fsSL https://get.docker.com -o /tmp/get-docker-host.sh
            sh /tmp/get-docker-host.sh
            rm /tmp/get-docker-host.sh
            systemctl enable docker
            systemctl start docker
            sleep 3
        fi

        # ── Configure insecure-registry on HOST ────────────
        echo "  → Configuring insecure-registry on host..."
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
                echo "  ✓ daemon.json updated, Docker restarted"
            else
                echo "  ✓ insecure-registry already configured on host"
            fi
        else
            mkdir -p /etc/docker
            cat > /etc/docker/daemon.json <<JSON
{
  "insecure-registries": ["${BRIDGE_IP}:5000"]
}
JSON
            systemctl restart docker && sleep 3
            echo "  ✓ daemon.json created, Docker restarted"
        fi
        # ────────────────────────────────────────────────────

        # Start registry if not running
        if ! docker ps | grep -q local-registry; then
            echo "  → Starting local registry on $BRIDGE_IP:5000..."
            docker stop local-registry 2>/dev/null || true
            docker rm local-registry 2>/dev/null || true
            docker run -d \\
                --name local-registry \\
                --restart=always \\
                -p 5000:5000 \\
                -v /var/lib/local-registry:/var/lib/registry \\
                registry:2
            sleep 2
            echo "  ✓ Registry started"
        else
            echo "  ✓ Registry already running"
        fi

        # Download image and push to registry (only if not already there)
        if curl -sf "http://${BRIDGE_IP}:5000/v2/crawl4ai/tags/list" | grep -q "0.7.3" 2>/dev/null; then
            echo "  ✓ Image already in registry — no internet needed"
        else
            echo "  → Downloading image from internet (once for all containers)..."
            if ! docker images | grep -q "unclecode/crawl4ai.*0.7.3"; then
                docker pull unclecode/crawl4ai:0.7.3
            fi
            docker tag unclecode/crawl4ai:0.7.3 "${BRIDGE_IP}:5000/crawl4ai:0.7.3"
            docker push "${BRIDGE_IP}:5000/crawl4ai:0.7.3"
            echo "  ✓ Image uploaded to registry"
        fi

        USE_LOCAL=true
    fi

    # ──────────────────────────────────────────────────────
    # STEP 2: Install CLI and image in each container
    # ──────────────────────────────────────────────────────
    echo ""
    echo "=== [2/3] Installing in containers ==="

    # Cache container list once
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        echo ""
        echo "─── ${CONTAINER_PREFIX}${i} ───────────────────────────────"
        echo "$LXC_LIST" | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "  container not found, skipping"; continue; }

        # Install CLI
        if lxc exec ${CONTAINER_PREFIX}${i} -- test -f /usr/local/bin/optimai-cli 2>/dev/null; then
            echo "  ✓ optimai-cli already installed"
        else
            echo "  → Installing optimai-cli..."
            lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
                curl -L https://optimai.network/download/cli-node/linux -o /tmp/optimai-cli &&
                chmod +x /tmp/optimai-cli &&
                mv /tmp/optimai-cli /usr/local/bin/optimai-cli
            " && echo "  ✓ optimai-cli installed" || echo "  ❌ CLI installation failed"
        fi

        # Install Docker image
        IMAGE_EXISTS=$(lxc exec ${CONTAINER_PREFIX}${i} -- bash -c \\
            'docker images 2>/dev/null | grep -q "unclecode/crawl4ai.*0.7.3" && echo "yes" || echo "no"')

        if [ "$IMAGE_EXISTS" = "yes" ]; then
            echo "  ✓ Docker image crawl4ai already present"
        elif [ "$USE_LOCAL" = "true" ]; then
            echo "  → Pulling image from host ($BRIDGE_IP:5000) without internet..."

            PULL_OK=false
            for attempt in 1 2 3; do
                [ $attempt -gt 1 ] && echo "  🔄 Attempt $attempt..."
                lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
                    mkdir -p /etc/docker
                    if [ -f /etc/docker/daemon.json ]; then
                        if ! grep -q 'insecure-registries' /etc/docker/daemon.json; then
                            python3 -c \\"
import json
with open('/etc/docker/daemon.json') as f:
    d = json.load(f)
d['insecure-registries'] = ['${BRIDGE_IP}:5000']
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(d, f, indent=2)
\\"
                            systemctl restart docker && sleep 3
                        fi
                    else
                        cat > /etc/docker/daemon.json <<JSON
{
  \\"storage-driver\\": \\"overlay2\\",
  \\"insecure-registries\\": [\\"${BRIDGE_IP}:5000\\"],
  \\"log-driver\\": \\"json-file\\",
  \\"log-opts\\": {\\"max-size\\": \\"10m\\", \\"max-file\\": \\"3\\"}
}
JSON
                        systemctl restart docker && sleep 3
                    fi
                    docker pull ${BRIDGE_IP}:5000/crawl4ai:0.7.3 &&
                    docker tag ${BRIDGE_IP}:5000/crawl4ai:0.7.3 unclecode/crawl4ai:0.7.3
                " && { PULL_OK=true; break; } || sleep 5
            done

            if [ "$PULL_OK" = "true" ]; then
                echo "  ✓ Image installed from local registry"
            else
                echo "  ❌ Image pull failed after 3 attempts"
            fi
        else
            echo "  → Downloading image from internet..."
            lxc exec ${CONTAINER_PREFIX}${i} -- bash -c \\
                "docker pull unclecode/crawl4ai:0.7.3" \\
                && echo "  ✓ Image downloaded" || echo "  ❌ Download failed"
        fi
    done

    # ── Clean up image from host after distribution ──
    if [ "$USE_LOCAL" = "true" ]; then
        echo ""
        echo "=== [3/3] Cleaning up host image ==="
        docker rmi "${BRIDGE_IP}:5000/crawl4ai:0.7.3" 2>/dev/null && \\
            echo "  ✓ Removed tag ${BRIDGE_IP}:5000/crawl4ai:0.7.3" || \\
            echo "  — tag already removed"
        docker rmi "unclecode/crawl4ai:0.7.3" 2>/dev/null && \\
            echo "  ✓ Removed image unclecode/crawl4ai:0.7.3" || \\
            echo "  — image already removed"
        echo "  ✓ Host storage freed"
    fi
    # ─────────────────────────────────────────────────────────

    echo ""
    echo "✅ Installation completed"
    read -p "Press Enter..."
}

update_optimai() {
    echo ""
    echo "=========================================="
    echo " OPTIMAI CLI UPDATE"
    echo "=========================================="
    local max=$(get_max_container)
    echo "Where to update? (5, 1-10, Enter=all)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        lxc list -c n --format csv | grep -q "^${CONTAINER_PREFIX}${i}$" || { echo "not found"; continue; }
        lxc exec ${CONTAINER_PREFIX}${i} -- /usr/local/bin/optimai-cli update 2>/dev/null && echo "OK" || echo "error"
    done
    echo ""
    echo "Update completed"
    read -p "Press Enter..."
}

login_optimai() {
    echo ""
    echo "=========================================="
    echo " OPTIMAI LOGIN"
    echo "=========================================="

    if [ -f "$CREDENTIALS_FILE" ]; then
        echo "Saved credentials found. Choose action: 1 — use saved credentials, 2 — enter new ones."
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
    echo "Which containers? (5, 1-10, Enter=all)"
    read -r range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Press Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    # Cache container list once
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        echo -n "[$i] ${CONTAINER_PREFIX}${i}: "
        if ! echo "$LXC_LIST" | grep -q "^${CONTAINER_PREFIX}${i}$"; then
            echo "not found"
            continue
        fi

        lxc exec ${CONTAINER_PREFIX}${i} -- bash -c "
            [ -f /usr/local/bin/optimai-cli ] || { echo 'CLI not installed'; exit 1; }
            command -v expect >/dev/null || { apt-get update -qq && apt-get install -y --no-install-recommends expect -qq >/dev/null; }
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
            puts \"✗ No Password field\"
            exit 1
        }
    }
    timeout {
        puts \"✗ No Email field\"
        exit 1
    }
}
EOF
        " && echo "OK" || echo "FAIL"
        sleep 1
    done

    echo ""
    echo "Login completed"
    read -p "Press Enter..."
}

# ============================================
# BLOCK 3: NODE MANAGEMENT
# ============================================

start_nodes() {
    local max=$(get_max_container)
    echo "Which nodes to start? (e.g.: 5, 1-10 or Enter for all 1-$max)"
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
    for i in $(seq 1 15); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
fi

echo "[3/6] Checking storage driver..."
DRIVER=$(docker info --format "{{.Driver}}" 2>/dev/null || echo "none")
if [ "$DRIVER" != "overlay2" ]; then
    echo "❌ CRITICAL: Docker using '$DRIVER' instead of overlay2!"
    echo "Run menu item 3 (Docker Setup) first"
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

echo "[6/6] Checking startup..."
if pgrep -f 'optimai-cli' >/dev/null; then
    PID=$(pgrep -f 'optimai-cli')
    echo "✅ Process started (PID: $PID)"
    echo ""
    echo "First lines of log:"
    head -20 /var/log/optimai/node.log 2>/dev/null || echo "Log empty"
else
    echo "❌ Startup failed!"
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
            echo "❌ ${CONTAINER_PREFIX}${i} start failed"
        fi
        sleep 2
    done

    echo ""
    echo "✅ Startup completed"
    read -p "Press Enter to continue..."
}

stop_nodes() {
    local max=$(get_max_container)
    echo "Which nodes to stop? (5, 1-10, Enter for all 1-$max)"
    read -r range

    result=$(parse_range "$range")
    if [ $? -ne 0 ]; then
        echo "✗ $result"
        read -p "Enter..."
        return
    fi

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    echo "Stopping nodes from ${CONTAINER_PREFIX}${start} to ${CONTAINER_PREFIX}${end}..."

    # Cache container list once
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        container="${CONTAINER_PREFIX}${i}"
        if ! echo "$LXC_LIST" | grep -q "^${container}$"; then
            echo "[$i] $container: not found, skipping"
            continue
        fi
        echo -n "[$i] $container: "
        lxc exec "$container" -- bash -c '
            # 1. First kill optimai-cli to prevent Docker restart
            pkill -9 -f "optimai-cli" 2>/dev/null || true
            sleep 1
            # 2. Then stop Docker container
            if command -v docker >/dev/null 2>&1; then
                RUNNING=$(docker ps -q)
                [ -n "$RUNNING" ] && docker stop --time=5 $RUNNING 2>/dev/null || true
            fi
        ' || true
        echo "✓ stopped"
    done

    echo ""
    echo "✅ Stop completed"
    read -p "Press Enter..."
}

# ============================================
# FUNCTION: LXD Container Deletion
# ============================================
delete_containers() {
    local max=$(get_max_container)
    echo ""
    echo "=========================================="
    echo " LXD CONTAINER DELETION"
    echo "=========================================="
    echo ""
    echo "What to delete:"
    echo "  • Single container:  5"
    echo "  • Range:             3-7"
    echo "  • All containers:    Enter"
    echo ""
    read -p "Number or range (1-$max): " range
    result=$(parse_range "$range")
    [ $? -ne 0 ] && { echo "✗ $result"; read -p "Enter..."; return; }

    start=$(echo $result | cut -d' ' -f1)
    end=$(echo $result | cut -d' ' -f2)

    if [ "$start" -eq "$end" ]; then
        echo ""
        echo "⚠️  Container to be deleted: ${CONTAINER_PREFIX}${start}"
    else
        echo ""
        echo "⚠️  Containers to be deleted: ${CONTAINER_PREFIX}${start} — ${CONTAINER_PREFIX}${end} ($((end - start + 1)) pcs.)"
    fi

    read -p "Confirm deletion? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Cancelled"; read -p "Enter..."; return; }

    # Cache container list once
    LXC_LIST=$(lxc list -c n --format csv)

    for i in $(seq $start $end); do
        container="${CONTAINER_PREFIX}${i}"
        if ! echo "$LXC_LIST" | grep -q "^${container}$"; then
            echo "[$i] $container: not found, skipping"
            continue
        fi
        echo -n "[$i] $container: stopping... "
        lxc stop "$container" --force 2>/dev/null || true
        echo -n "deleting... "
        lxc delete "$container" 2>/dev/null || true
        echo "✓ deleted"
    done

    echo ""
    echo "✅ Deletion completed"
    read -p "Press Enter..."
}

view_logs() {
    local max=$(get_max_container)
    echo "Container number (1-$max):"
    read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$max" ] && { echo "Invalid"; read -p "Enter..."; return; }

    echo "=== Logs ${CONTAINER_PREFIX}${num} ==="
    lxc exec ${CONTAINER_PREFIX}${num} -- bash -c '
        if [ -f /var/log/optimai/node.log ]; then
            tail -50 /var/log/optimai/node.log
        else
            echo "No logs"
            ps aux | grep optimai | grep -v grep || echo "Process not running"
        fi
    '
    echo ""
    read -p "Follow in real time? (y/n): " follow
    [ "$follow" = "y" ] && lxc exec ${CONTAINER_PREFIX}${num} -- tail -f /var/log/optimai/node.log
}

check_status() {
    echo "=== NODE STATUS ==="
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
                RUNNING) status="🟢 RUNNING" ;;
                CRASHED) status="🟡 DOCKER STOPPED" ;;
                *)       status="🔴 STOPPED" ;;
            esac

            echo "${CONTAINER_PREFIX}${i}: $status | Docker: $driver"
        fi
    done
    read -p "Press Enter..."
}

# === Main menu ===
while true; do
    clear
    echo "=========================================="
    echo " LXD + DOCKER + OPTIMAI MANAGER v2.1"
    echo "=========================================="
    echo ""

    echo "=== INSTALLATION AND SETUP ==="
    echo "1) System update"
    echo "2) LXD installation and container creation"
    echo "3) Docker setup inside containers"
    echo "4) OptimAI CLI installation in containers"
    echo ""

    echo "=== OPTIMAI NODE MANAGEMENT ==="
    echo "5) OptimAI login in containers"
    echo "6) Start nodes"
    echo "7) Stop nodes"
    echo "8) View logs"
    echo "9) Check all nodes status"
    echo ""

    echo "=== ADDITIONAL ==="
    echo "10) SWAP file setup"
    echo "11) OptimAI CLI update"
    echo "12) Delete LXD containers"
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
        12) delete_containers ;;
        13) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid choice"; sleep 2 ;;
    esac
done
