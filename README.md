Here is the fully translated and formatted **README.md** in English, ready for your GitHub repository.


# OptimAI LXD Node Manager v2.0 🚀

[![OptimAI](https://img.shields.io/badge/Project-OptimAI-blue.svg)](https://optimai.network)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An automated script to run up to **30 OptimAI nodes** on a single VPS using LXD containers. Each node operates in an isolated environment with its own Docker daemon and unique hardware fingerprint to maximize efficiency and rewards.

> **Earn 3,500+ points every single day** on a single server setup!

---

## 📊 Performance Results
![Rewards Statistics](https://static.teletype.in/files/5a/04/5a0445f1-344c-4712-9883-820876127e4e.png)
*Consistent point farming achieved by running 30 nodes simultaneously.*

---

## 💻 System Requirements
To run 30 nodes smoothly, we recommend the following configuration:
* **OS:** Ubuntu 22.04 (Required)
* **CPU:** 8 Cores+
* **RAM:** 32 GB+
* **Disk:** 100 GB SSD/NVMe

### Recommended VPS Providers:
* [Lumadock](https://lumadock.com/aff.php?aff=107) (Optimized for node farming)
* [Contabo](https://www.dpbolvw.net/click-101335050-13484397) (Reliable budget option)

---

## 🚀 Quick Installation

Run the following command to download, set permissions, and launch the manager:

```bash
wget -O lxd_optimai_manager.sh [https://raw.githubusercontent.com/VaniaHilkovets/optimai_lxd_cli/main/lxd_optimai_manager_eng.sh](https://raw.githubusercontent.com/VaniaHilkovets/optimai_lxd_cli/main/lxd_optimai_manager_eng.sh) \
&& chmod +x lxd_optimai_manager.sh \
&& ./lxd_optimai_manager.sh

```

### Management Menu

---

## 🛠 Menu Function Overview

### 1. Installation and Setup

* **Update System (1):** Updates OS packages and installs core dependencies.
* **Install LXD & Create Containers (2):** Configures the virtualization platform and creates isolated containers.
* **Setup Docker inside Containers (3):** Installs Docker environment within each container. *(Note: This step takes time as it processes each node individually).*
* **Install CLI (4):** Downloads the node management tool into the containers.

### 2. Node Management

* **Login (5):** Automates the authorization process across all selected containers.
* **Start Nodes (6):** Launches node workflows in the background.
* **Stop Nodes (7):** Safely terminates operations.
* **View Logs (8):** Displays real-time activity and event history for a specific node.
* **Check Status (9):** Provides a summary of which nodes are currently running or stopped.

### 3. Additional Tools

* **Configure SWAP (10):** Creates a swap file (Highly recommended if RAM is under 32GB).
* **Update CLI (11):** Checks for and installs the latest version of the management software.
* **Delete All Containers (12):** Completely removes all containers and wipes the system clean.

---

## 📖 Quick Start Guide

1. **Full Setup:** Execute menu options **1 through 6** sequentially for a complete installation.
2. **Memory Optimization:** If your server has limited RAM, ensure you use **Option 10** before starting the nodes.
3. **Scaling:** You can install containers in parts. To add more nodes later, simply run **Option 2** again and follow the sequence for the new containers.

---

## 📞 Contact & Support

If you encounter any errors or need assistance, feel free to reach out:

* **Telegram Support:** [@Vania_ls](https://t.me/Vania_ls)
* **Telegram Channel:** [SotochkaZela](https://t.me/SotochkaZela)
* **Twitter (X):** [@Gooszilla](https://x.com/Gooszilla)

---

*Disclaimer: Use this script at your own risk. Always monitor your VPS resource usage.*

```

