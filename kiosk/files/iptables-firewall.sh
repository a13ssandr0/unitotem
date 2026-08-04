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

  # IPv6, mirroring the rules above. Previously absent entirely, which meant
  # IPv4 defaulted to DROP while IPv6 was left wide open - the opposite of
  # what the policy above intends. It matters more now that link-local IPv6
  # is a guaranteed rescue channel (see kiosk/files/nm-fallback.nmconnection):
  # that channel must be reachable, but only on the same ports IPv4 exposes.
  ip6tables -F
  ip6tables -P INPUT   DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT  ACCEPT
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # ICMPv6 is accepted wholesale, unlike ICMP on IPv4 where it is a
  # convenience. Here it is load-bearing: Neighbour Discovery, Router
  # Solicitation/Advertisement and Duplicate Address Detection all ride on
  # ICMPv6, so dropping it does not harden IPv6 - it breaks it, including
  # the link-local address this rescue path depends on.
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 80  -j ACCEPT
  ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
  ip6tables -A INPUT -p udp --dport 5353 -j ACCEPT
}

# clear iptables configuration
firewall_stop() {
  iptables -F
  iptables -X
  iptables -P INPUT   ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT  ACCEPT
  ip6tables -F
  ip6tables -X
  ip6tables -P INPUT   ACCEPT
  ip6tables -P FORWARD ACCEPT
  ip6tables -P OUTPUT  ACCEPT
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