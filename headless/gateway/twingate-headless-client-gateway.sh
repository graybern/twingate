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

# ============================================================
# Prompt user for interfaces
# ============================================================

read -p "What interface will be the WAN port (e.g., wlan0, eth0)? " WAN_INTERFACE
read -p "Do you want to enable DHCP? (yes/no) " ENABLE_DHCP
if [[ "$ENABLE_DHCP" == "yes" ]]; then
  read -p "Which interface should DHCP be enabled on (e.g., eth0)? " LAN_INTERFACE
  read -p "Enter DHCP range (e.g., 192.168.100.100,192.168.100.150,12h): " DHCP_RANGE
  read -p "Enter DHCP gateway IP (e.g., 192.168.100.1): " DHCP_GATEWAY
  read -p "Enter DHCP DNS IP (e.g., 192.168.100.1): " DHCP_DNS
else
  read -p "Which interface will act as LAN (e.g., eth0)? " LAN_INTERFACE
fi

# ============================================================
# Optional Allowed IPs
# ============================================================
read -p "Do you want to allow specific IPs for routing and DNS? (yes/no) " ALLOW_SPECIFIC_IPS

if [[ "$ALLOW_SPECIFIC_IPS" == "yes" ]]; then
  read -p "Enter comma-separated list of allowed IPs (e.g., 192.168.1.100,192.168.1.101): " ALLOWED_IPS
fi

# ============================================================
# Validate and set inputs
# ============================================================

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo."
  exit 1
fi

if [ -z "$1" ] || [ ! -f "$1" ]; then
  echo "Please provide a valid Twingate service key file as the first argument."
  exit 1
fi
TWINGATE_SERVICE_KEY_FILE="$1"

if [ -z "$2" ]; then
  echo "Please provide the local network subnet as the second argument (format: x.x.x.x/xx)."
  exit 1
fi
LOCAL_NETWORK_SUBNET="$2"

MAIN_NETWORK_INTERFACE_IP=$(ip -4 addr show "$WAN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# ============================================================
# Detect Package Manager
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
# Install Required Packages
# ============================================================

if [ "$PKG_MANAGER" = "dnf" ]; then
  $PKG_MANAGER -y update
  $PKG_MANAGER install -y dnsmasq curl iptables-services
  systemctl enable iptables && systemctl start iptables
else
  $PKG_MANAGER update -y
  $PKG_MANAGER install -y dnsmasq iptables iptables-persistent curl
fi

# ============================================================
# Stop services using port 53 (DNS)
# ============================================================

systemctl stop systemd-resolved || true
systemctl disable systemd-resolved || true
echo "nameserver $MAIN_NETWORK_INTERFACE_IP" > /etc/resolv.conf

# ============================================================
# Install and configure Twingate client
# ============================================================

curl https://binaries.twingate.com/client/linux/install.sh | sudo bash
sudo twingate setup --headless "$TWINGATE_SERVICE_KEY_FILE"
systemctl enable --now twingate

# ============================================================
# Configure LAN interface with static IP
# ============================================================

ip addr flush dev "$LAN_INTERFACE"
ip addr add "$DHCP_GATEWAY"/24 dev "$LAN_INTERFACE"
ip link set "$LAN_INTERFACE" up

# ============================================================
# Configure dnsmasq
# ============================================================

mkdir -p /etc/dnsmasq.d
cat <<EOF > /etc/dnsmasq.d/twingate-gateway.conf
# Specify the interface for the DHCP server
interface=$LAN_INTERFACE

listen-address=127.0.0.1,$MAIN_NETWORK_INTERFACE_IP,$DHCP_GATEWAY
no-resolv
domain-needed
bogus-priv

# DHCP settings
EOF

if [[ "$ENABLE_DHCP" == "yes" ]]; then
cat <<EOF >> /etc/dnsmasq.d/twingate-gateway.conf
dhcp-range=$DHCP_RANGE
dhcp-option=3,$DHCP_GATEWAY
dhcp-option=6,$DHCP_DNS
EOF
fi

# DNS via Twingate
cat <<EOF >> /etc/dnsmasq.d/twingate-gateway.conf
server=100.95.0.251
server=100.95.0.252
server=100.95.0.253
server=100.95.0.254
EOF

# Configure dnsmasq for Allowed IPs
if [[ "$ALLOW_SPECIFIC_IPS" == "yes" && -n "$ALLOWED_IPS" ]]; then
  IFS=',' read -r -a ALLOWED_IP_ARRAY <<< "$ALLOWED_IPS"
  
  # Only provide DNS for the specified IPs
  for ip in "${ALLOWED_IP_ARRAY[@]}"; do
    echo "Limiting DNS access to IP: $ip"

    # Add the DHCP and DNS options for each allowed IP
    echo "dhcp-option=3,$ip" >> /etc/dnsmasq.d/twingate-gateway.conf  # Gateway for each IP
    echo "dhcp-option=6,$ip" >> /etc/dnsmasq.d/twingate-gateway.conf  # DNS for each IP
  done
fi

systemctl restart dnsmasq
systemctl enable dnsmasq

# ============================================================
# Enable NAT
# ============================================================

iptables -t nat -A POSTROUTING -s "$LOCAL_NETWORK_SUBNET" -o sdwan0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$LOCAL_NETWORK_SUBNET" -o "$WAN_INTERFACE" -j MASQUERADE

iptables -A FORWARD -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT
iptables -A FORWARD -i "$LAN_INTERFACE" -o sdwan0 -j ACCEPT
iptables -A FORWARD -i "$WAN_INTERFACE" -o "$LAN_INTERFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i sdwan0 -o "$LAN_INTERFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Configure iptables for Allowed IPs
if [[ "$ALLOW_SPECIFIC_IPS" == "yes" && -n "$ALLOWED_IPS" ]]; then
  IFS=',' read -r -a ALLOWED_IP_ARRAY <<< "$ALLOWED_IPS"
  
  for ip in "${ALLOWED_IP_ARRAY[@]}"; do
    echo "Allowing IP $ip through the gateway..."

    # Allow forwarding from specific IPs to the Twingate tunnel
    iptables -A FORWARD -s "$ip" -o sdwan0 -j ACCEPT

    # Allow incoming traffic on LAN interface from the allowed IPs
    iptables -A INPUT -s "$ip" -i "$LAN_INTERFACE" -j ACCEPT
  done
else
  echo "No specific IPs specified, allowing all traffic..."
fi

if [ "$PKG_MANAGER" = "dnf" ]; then
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
# Done
# ============================================================

echo "✅ Twingate Gateway setup is complete."
echo "dnsmasq configuration saved to /etc/dnsmasq.d/twingate-gateway.conf"
