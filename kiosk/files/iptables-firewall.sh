#!/bin/bash
# Configure iptables firewall

# Limit PATH
PATH="/sbin:/usr/sbin:/bin:/usr/bin"

# iptables configuration
firewall_start() {
  iptables -F                                                             # Flush all current rules from iptables
  iptables -P INPUT   DROP                                                # Default rules
  iptables -P FORWARD DROP
  iptables -P OUTPUT  ACCEPT
  iptables -A INPUT -i lo -j ACCEPT                                       # Accept everything on loopback
  iptables -A INPUT -m conntrack --ctstate INVALID -j DROP                # Drop invalid packets
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT  # Accept incoming packets for established connections
  iptables -A INPUT -p icmp -j ACCEPT                                     # Accept incoming ICMP
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT                           # Accept incoming SSH
  iptables -A INPUT -p tcp --dport 80  -j ACCEPT                          # Accept incoming HTTP/S
  iptables -A INPUT -p tcp --dport 443 -j ACCEPT
  iptables -A INPUT -p udp --dport 5353 -j ACCEPT                         # Accept incoming avahi/zeroconf
}

# clear iptables configuration
firewall_stop() {
  iptables -F
  iptables -X
  iptables -P INPUT   ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT  ACCEPT
}

# execute action
case "$1" in
  start|restart)
    echo "Starting firewall"
    firewall_stop
    firewall_start
    ;;
  stop)
    echo "Stopping firewall"
    firewall_stop
    ;;
esac