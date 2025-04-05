# 🛡️ Twingate Headless Client Gateway

This project provides a script to automate the setup of a **network-level Internet Gateway** using the **Twingate Headless Client**. It's designed for environments with **IoT devices** or other clients that can't install the traditional Twingate client. These devices can instead route traffic through this gateway to access:

- Public Internet
- Twingate-protected private resources

---

## 🚀 What This Script Sets Up

On a supported Linux system, the script configures:

- ✅ **Twingate Headless Client**  
- ✅ **Bind9** (as a DNS server using Twingate DNS resolvers)  
- ✅ **iptables** (to enable NAT and packet forwarding)  
- ✅ Proper IPv4 forwarding and persistent configuration

The end result is a system that acts as a **DNS server and NAT gateway** for other devices on your LAN.

---

## 🧰 Prerequisites

Before running the script:

1. **Twingate Service Account**
   - In the Twingate Admin Console, go to **Teams > Services**, and create a new **Service Account**.
   - Generate a **Service Key**, and save the resulting `.json` as `servicekey.json`.

2. **Static IP & Internet Access**
   - Ensure the system running the gateway has a **static IP** and **Internet access**.

3. **Supported Systems**
   - Tested on: Ubuntu, Debian, Fedora (support for RHEL planned).

---

## 🛠️ Installation

1. **Download the script:**

```bash
curl -o tg-gateway.sh https://raw.githubusercontent.com/graybern/twingate/refs/heads/main/headless/gateway/twingate-headless-client-gateway.sh \
  && chmod +x tg-gateway.sh
```

2. **Run the script with required arguments:**

```bash
sudo ./tg-gateway.sh ./servicekey.json 192.168.1.0/24
```

- `./servicekey.json`: Path to your saved Twingate service key file
- `192.168.1.0/24`: Subnet of your local network

---

## 🧪 What the Script Does

Upon execution, the script:

1. Installs required packages (`bind9`, `iptables`, `curl`, `twingate`)
2. Configures **Bind9** to use Twingate's internal DNS resolvers:
   - `100.95.0.251–254`
3. Sets up **iptables NAT** to forward traffic from your LAN to Twingate (via `sdwan0`)
4. Enables **IPv4 packet forwarding** system-wide
5. Starts and enables services on boot

---

## ✅ Testing the Gateway

1. **Add Resources to the Service Account**
   - In the Twingate Admin Console, assign access to protected resources for the Service Account.

2. **Test from the gateway itself**
   - Run `ping` or `curl` to verify connectivity to remote/private services.

3. **Point another device to the gateway**
   - Set the device’s **default gateway** and **DNS server** to the IP of the gateway machine.
   - Try accessing:
     - Public sites (e.g., `google.com`)
     - Private Twingate Resources (e.g., internal apps, VMs)

---

## 💡 Notes & Recommendations

- The Twingate Agent creates a virtual interface called `sdwan0` for routing traffic.
- Make sure no firewall is blocking outbound traffic or DNS queries.
- Avoid exposing this setup to the internet without additional security layers (like a VPN or access control).
