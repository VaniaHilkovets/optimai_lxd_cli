
# OptimAI LXD Node Manager 🚀

[![OptimAI](https://img.shields.io/badge/Project-OptimAI-blue.svg)](https://optimai.network)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An automated script to run up to **30 OptimAI nodes** on a single VPS using LXD containers. Each node operates in an isolated environment with its own Docker daemon and unique hardware fingerprint to maximize efficiency and rewards.

> **Earn 3,500+ points every single day** on a single server setup!

---

## 📊 Performance Results

![Rewards Statistics](https://img2.teletype.in/files/57/3a/573aa2b9-2eca-4387-9d5a-5c8aa90340b0.png)

*Consistent point farming achieved by running 30 nodes simultaneously.*

---

## 💻 System Requirements

To run 30 nodes smoothly, we recommend the following configuration:

* **OS:** Ubuntu 22.04 (Required)
* **CPU:** 8 Cores+
* **RAM:** 32 GB+
* **Disk:** 250 GB SSD/NVMe

### Recommended VPS Providers

* [Contabo](https://www.dpbolvw.net/click-101335050-13484397) — Reliable budget option
* [Lumadock](https://lumadock.com/aff.php?aff=107) — Optimized for node farming

---

## 🚀 Quick Installation

Run the following command to download, set permissions, and launch the manager:

```bash
wget -O lxd_optimai_manager.sh https://raw.githubusercontent.com/VaniaHilkovets/optimai_lxd_cli/main/lxd_optimai_manager_eng.sh \
&& chmod +x lxd_optimai_manager.sh \
&& ./lxd_optimai_manager.sh
````

---

## 🛠 Menu Function Overview

### 1. Installation and Setup

* **Update System (1):** Updates OS packages and installs core dependencies.
* **Install LXD & Create Containers (2):** Configures the virtualization platform and creates isolated containers.
* **Setup Docker inside Containers (3):** Installs Docker environment within each container.
  *(Note: This step takes time as it processes each node individually).*
* **Install CLI (4):** Downloads the node management tool into the containers.

### 2. Node Management

* **Login (5):** Automates the authorization process across all selected containers.
* **Start Nodes (6):** Launches node workflows in the background.
* **Stop Nodes (7):** Safely terminates operations.
* **View Logs (8):** Displays real-time activity and event history for a specific node.
* **Check Status (9):** Provides a summary of which nodes are currently running or stopped.

### 3. Additional Tools

* **Configure SWAP (10):** Creates a swap file.
  *(Highly recommended if RAM is under 32GB).*
* **Update CLI (11):** Checks for and installs the latest version of the management software.
* **Delete All Containers (12):** Completely removes all containers and wipes the system clean.

---

## 📖 Quick Start Guide

1. **Full Setup:** Execute menu options **1 through 6** sequentially for a complete installation.
2. **Memory Optimization:** If your server has limited RAM, use **Option 10** before starting the nodes.
3. **Scaling:** You can install containers in parts. To add more nodes later, simply run **Option 2** again and follow the sequence for the new containers.

---

## 🛡 Watchdog for Auto-Restart of Failed Nodes

To improve stability, you can use the **watchdog script**, which continuously monitors your OptimAI nodes, automatically restarts nodes that have crashed or become stuck, and performs daily cleanup of temporary files and logs so they do not fill up your disk.

This is especially useful when running many containers at once, because some nodes may occasionally freeze, stop responding, or silently fail over time.

### Install and Run Watchdog

Use this command to download, make executable, and launch the watchdog in the background:

```bash
cd /root && curl -L https://raw.githubusercontent.com/VaniaHilkovets/optimai_lxd_cli/main/watchdog.sh -o watchdog.sh && chmod +x watchdog.sh && nohup ./watchdog.sh > /var/log/optimai_watchdog_stdout.log 2>&1 &
```

### Check Watchdog Logs

To monitor watchdog activity in real time, run:

```bash
tail -f /var/log/optimai_watchdog.log
```

### What the Watchdog Does

* Automatically monitors OptimAI nodes
* Detects crashed or frozen nodes
* Restarts failed nodes without manual intervention
* Cleans temporary `_MEI*` folders created by the node inside containers once per day
* Runs daily Docker cleanup, truncates Docker logs, and vacuums old journal logs to free disk space
* Helps keep your farming stable 24/7

> **Recommended:** Start the watchdog after all nodes are installed, logged in, and running.

---

## 📞 Contact & Support

If you encounter any errors or need assistance, feel free to reach out:

* **Telegram Support:** [@Vania_ls](https://t.me/Vania_ls)
* **Telegram Channel:** [SotochkaZela](https://t.me/SotochkaZela)
* **Twitter (X):** [@Gooszilla](https://x.com/Gooszilla)

---

## ⚠ Disclaimer

Use this script at your own risk. Always monitor your VPS resource usage and node performance.
