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
# sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24

# ============================================================
# Display Help/Usage
# ============================================================
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: sudo ./twingate-gateway.sh /path/to/twingate-service-key.json 10.0.0.0/24"
  echo "  /path/to/twingate-service-key.json - Location of the Twingate service key file."
  echo "  10.0.0.0/24 - Local network subnet."
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
# Check if Twingate service key file is provided
if [ -z "$1" ]; then
  echo "Please provide the location of the Twingate service key file as the first argument."
  exit 1
fi

# Check if the Twingate service key file exists
if [ ! -f "$1" ]; then
  echo "The Twingate service key file does not exist, or is in the wrong position."
  exit 1
fi

# Assign the Twingate service key file to a variable
TWINGATE_SERVICE_KEY_FILE="$1"

# Check if the local network subnet is provided
if [ -z "$2" ]; then
  echo "Please provide the local network subnet as the second argument (format: x.x.x.x/xx)."
  exit 1
fi

# Validate the local network subnet format
if ! echo "$2" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
  echo "The local network subnet is not valid."
  exit 1
fi

# Assign the local network subnet to a variable
LOCAL_NETWORK_SUBNET="$2"

# Get the main network interface IP address
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
# Update Package Repositories & Install Required Packages (bind, curl, iptables)
# ============================================================
if [ $PKG_MANAGER = "dnf" ]; then # Fedora
  $PKG_MANAGER -y update
  $PKG_MANAGER install -y bind curl
else # Ubuntu
  $PKG_MANAGER update -y
  $PKG_MANAGER install -y bind9 iptables iptables-persistent curl
fi

# ============================================================
# Install Twingate Client
# ============================================================
curl https://binaries.twingate.com/client/linux/install.sh | sudo bash
sudo twingate setup --headless $TWINGATE_SERVICE_KEY_FILE
#twingate start
systemctl start twingate
systemctl enable twingate

# ============================================================
# Configure Services (Bind DNS, iptables, Twingate)
# ============================================================
if [ $PKG_MANAGER = "dnf" ]; then 
# Fedora Configuration
# Configure bind DNS to listen on the main network interface IP address and the localhost in ipv4 mode only
# Note: The forwarders are set to the Twingate Client resolvers
cat <<EOF > /etc/named.conf
  acl LAN {
  $LOCAL_NETWORK_SUBNET;
  };
  options {
          directory "/var/named";
          allow-query { localhost; LAN; };
          recursion yes;
          forwarders {
                  100.95.0.251;
                  100.95.0.252;
                  100.95.0.253;
                  100.95.0.254;
          };
          dnssec-validation no;
          listen-on port 53 { 127.0.0.1;$MAIN_NETWORK_INTERFACE_IP; };
  };
EOF

  # Enable IPv4 only for Bind
  echo "OPTIONS=\"-4\"" >> /etc/sysconfig/named 

  # Restart and enable bind
  systemctl restart named
  systemctl enable named

  # Disable firewalld (not needed for iptables)
  dnf remove -y firewalld

  # Install iptables-services for NAT configuration
  dnf install -y iptables-services
  systemctl enable iptables
  systemctl start iptables

  # Configure NAT with iptables
  #iptables -t nat -A POSTROUTING -s 0.0.0.0/24 -o sdwan0 -j MASQUERADE
  iptables -t nat -A POSTROUTING -s $LOCAL_NETWORK_SUBNET -o sdwan0 -j MASQUERADE
  iptables-save > /etc/sysconfig/iptables
  systemctl restart iptables


else 
# Ubuntu Configuration
# Configure bind DNS to listen on the main network interface IP address and the localhost in ipv4 mode only
# Note: The forwarders are set to the Twingate Client resolvers
cat <<EOF > /etc/bind/named.conf.options
  acl LAN {
  $LOCAL_NETWORK_SUBNET;
  };
  options {
          directory "/var/cache/bind";
          allow-query { localhost; LAN; };
          recursion yes;
          forwarders {
                  100.95.0.251;
                  100.95.0.252;
                  100.95.0.253;
                  100.95.0.254;
          };
          dnssec-validation no;
          listen-on port 53 { 127.0.0.1;$MAIN_NETWORK_INTERFACE_IP; };
  };
EOF

  # Set Bind9 to IPv4 only
  sed -i 's/OPTIONS="-u bind"/OPTIONS="-u bind -4"/' /etc/default/named

  # Restart and enable Bind9
  #systemctl restart bind9
  systemctl restart named
  #systemctl enable bind9
  systemctl enable named

  # Configure NAT with iptables
  #iptables -t nat -A POSTROUTING -s 0.0.0.0/24 -o sdwan0 -j MASQUERADE
  iptables -t nat -A POSTROUTING -s $LOCAL_NETWORK_SUBNET -o sdwan0 -j MASQUERADE
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
