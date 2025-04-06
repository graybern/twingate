#!/bin/bash

# ============================================================
# Twingate Internet Gateway Configuration Script
# This script configures Ubuntu, Debian, or Fedora to function 
# as a Twingate Internet Gateway for the local network.
# ============================================================

# Prerequisites:
# 1. A Twingate Service Account.
# 2. A valid JSON Twingate configuration file.
# 3. The subnet of your local network.
# 4. This script should be run as root or with sudo.

# Example usage:
# sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24 [enable_dhcp] [dhcp_range] [dhcp_gateway] [dhcp_dns]

# ============================================================
# Display Help/Usage
# ============================================================
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24 [enable_dhcp] [dhcp_range] [dhcp_gateway] [dhcp_dns]"
  echo "  /path/to/twingate-service-key.json - Location of the Twingate service key file."
  echo "  10.0.0.0/24 - Local network subnet."
  echo "  enable_dhcp - Optional. yes or no (default: yes)."
  echo "  dhcp_range - Optional. Format: start,end,lease (default: 192.168.1.100,192.168.1.150,12h)"
  echo "  dhcp_gateway - Optional. Default: 192.168.1.193"
  echo "  dhcp_dns - Optional. Default: 192.168.1.193"
  exit 0
fi

# ============================================================
# Check for Root/Sudo Privileges
# ============================================================
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo."
  exit 1
fi

# ============================================================
# Validate Input Arguments
# ============================================================
if [ -z "$1" ] || [ ! -f "$1" ]; then
  echo "Please provide a valid Twingate service key file as the first argument."
  exit 1
fi
TWINGATE_SERVICE_KEY_FILE="$1"

if [ -z "$2" ]; then
  echo "Please provide the local network subnet as the second argument (format: x.x.x.x/xx)."
  exit 1
fi
if ! echo "$2" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
  echo "The local network subnet is not valid."
  exit 1
fi
LOCAL_NETWORK_SUBNET="$2"

# Optional arguments
ENABLE_DHCP="${3:-yes}"
DHCP_RANGE="${4:-192.168.1.100,192.168.1.150,12h}"
DHCP_GATEWAY="${5:-192.168.1.193}"
DHCP_DNS="${6:-192.168.1.193}"

MAIN_NETWORK_INTERFACE_IP=$(ip -4 addr show $(ip route show default | awk '/default/ {print $5}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# ============================================================
# Identify Package Manager (apt-get or dnf)
# ============================================================
if [ -x "$(command -v apt-get)" ]; then
  PKG_MANAGER="apt-get"
elif [ -x "$(command -v dnf)" ]; then
  PKG_MANAGER="dnf"
else
  echo "No supported package manager found. Exiting."
  exit 1
fi

# ============================================================
# Update Package Repositories & Install Required Packages
# ============================================================
if [ $PKG_MANAGER = "dnf" ]; then
  $PKG_MANAGER -y update
  $PKG_MANAGER install -y dnsmasq curl iptables-services
  systemctl enable iptables && systemctl start iptables
else
  $PKG_MANAGER update -y
  $PKG_MANAGER install -y dnsmasq iptables iptables-persistent curl
fi

# ============================================================
# Stop any services using port 53 (like systemd-resolved)
# ============================================================
systemctl stop systemd-resolved || true
systemctl disable systemd-resolved || true

# ============================================================
# Install Twingate Client
# ============================================================
curl https://binaries.twingate.com/client/linux/install.sh | sudo bash
sudo twingate setup --headless $TWINGATE_SERVICE_KEY_FILE
systemctl start twingate
systemctl enable twingate

# ============================================================
# Configure dnsmasq for DNS (and optional DHCP)
# ============================================================
mkdir -p /etc/dnsmasq.d

cat <<EOF > /etc/dnsmasq.d/twingate-gateway.conf
interface=eth0
bind-interfaces
listen-address=127.0.0.1,$MAIN_NETWORK_INTERFACE_IP
no-resolv
server=100.95.0.251
server=100.95.0.252
server=100.95.0.253
server=100.95.0.254
domain-needed
bogus-priv
EOF

if [ "$ENABLE_DHCP" = "yes" ]; then
cat <<EOF >> /etc/dnsmasq.d/twingate-gateway.conf
dhcp-range=$DHCP_RANGE
dhcp-option=3,$DHCP_GATEWAY  # Gateway
dhcp-option=6,$DHCP_DNS      # DNS
EOF
fi

systemctl restart dnsmasq
systemctl enable dnsmasq

# ============================================================
# Configure NAT with iptables
# ============================================================
iptables -t nat -A POSTROUTING -s $LOCAL_NETWORK_SUBNET -o sdwan0 -j MASQUERADE
if [ $PKG_MANAGER = "dnf" ]; then
  iptables-save > /etc/sysconfig/iptables
else
  iptables-save > /etc/iptables/rules.v4
  systemctl restart iptables
fi

# ============================================================
# Enable IPv4 Forwarding
# ============================================================
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# ============================================================
# Script Completion
# ============================================================
echo "Twingate Internet Gateway configuration is complete."
echo "dnsmasq configuration saved to /etc/dnsmasq.d/twingate-gateway.conf"
cat /etc/dnsmasq.d/twingate-gateway.conf
