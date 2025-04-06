#!/bin/bash

# ============================================================
# Twingate Internet Gateway Configuration Script with dnsmasq
# ============================================================

# Usage:
# sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24 [ENABLE_DHCP] [DHCP_RANGE] [GATEWAY_IP] [DNS_SERVER]

# Example:
# sudo ./twingate-gateway.sh ./servicekey.json 192.168.210.0/24 yes 192.168.210.100,192.168.210.150,12h 192.168.210.193 192.168.210.193

# ============================================================
# Display Help/Usage
# ============================================================
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24 [ENABLE_DHCP] [DHCP_RANGE] [GATEWAY_IP] [DNS_SERVER]"
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
TWINGATE_SERVICE_KEY_FILE="$1"
LOCAL_NETWORK_SUBNET="$2"
ENABLE_DHCP="${3:-yes}"
DHCP_RANGE="${4:-192.168.210.100,192.168.210.150,12h}"
DHCP_GATEWAY="${5:-192.168.210.193}"
DHCP_DNS="${6:-192.168.210.193}"

if [ -z "$TWINGATE_SERVICE_KEY_FILE" ] || [ ! -f "$TWINGATE_SERVICE_KEY_FILE" ]; then
  echo "Please provide a valid Twingate service key file."
  exit 1
fi

if ! echo "$LOCAL_NETWORK_SUBNET" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
  echo "Invalid subnet format. Use x.x.x.x/xx"
  exit 1
fi

MAIN_NETWORK_INTERFACE_IP=$(ip -4 addr show $(ip route show default | awk '/default/ {print $5}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# ============================================================
# Identify Package Manager
# ============================================================
if [ -x "$(command -v apt-get)" ]; then
  PKG_MANAGER="apt-get"
elif [ -x "$(command -v dnf)" ]; then
  PKG_MANAGER="dnf"
else
  echo "Unsupported package manager."
  exit 1
fi

# ============================================================
# Install Required Packages
# ============================================================
$PKG_MANAGER update -y
$PKG_MANAGER install -y dnsmasq iptables iptables-persistent curl

# ============================================================
# Stop systemd-resolved if using port 53
# ============================================================
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null

if lsof -i :53; then
  echo "Port 53 still in use. Stop conflicting service."
  exit 1
fi

# ============================================================
# Install and Start Twingate Client
# ============================================================
curl https://binaries.twingate.com/client/linux/install.sh | sudo bash
sudo twingate setup --headless "$TWINGATE_SERVICE_KEY_FILE"
systemctl start twingate
systemctl enable twingate

# ============================================================
# Configure dnsmasq
# ============================================================
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup

cat <<EOF > /etc/dnsmasq.conf
interface=eth0
bind-interfaces
listen-address=127.0.0.1,$MAIN_NETWORK_INTERFACE_IP
domain-needed
bogus-priv
no-resolv
server=100.95.0.251
server=100.95.0.252
server=100.95.0.253
server=100.95.0.254
EOF

if [ "$ENABLE_DHCP" = "yes" ]; then
cat <<EOF >> /etc/dnsmasq.conf

dhcp-range=$DHCP_RANGE
dhcp-option=3,$DHCP_GATEWAY
dhcp-option=6,$DHCP_DNS
EOF
fi

systemctl restart dnsmasq
systemctl enable dnsmasq

# ============================================================
# Enable NAT & IP Forwarding
# ============================================================
iptables -t nat -A POSTROUTING -s "$LOCAL_NETWORK_SUBNET" -o sdwan0 -j MASQUERADE
iptables-save > /etc/iptables/rules.v4

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# ============================================================
# Done
# ============================================================
echo "Twingate Internet Gateway configuration complete."
echo "DHCP Enabled: $ENABLE_DHCP"
echo "DHCP Range: $DHCP_RANGE"
echo "Gateway IP: $DHCP_GATEWAY"
echo "DNS Server: $DHCP_DNS"
