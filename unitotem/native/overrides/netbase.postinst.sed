# the hosts and networks files are created under DPKG_ROOT (the builder's own files are not the target's)
s#\[ -e /etc/hosts \]#[ -e "${DPKG_ROOT}/etc/hosts" ]#
s#cat > /etc/hosts <<-EOF#cat > "${DPKG_ROOT}/etc/hosts" <<-EOF#
s#\[ -e /etc/networks \]#[ -e "${DPKG_ROOT}/etc/networks" ]#
s#cat > /etc/networks <<-EOF#cat > "${DPKG_ROOT}/etc/networks" <<-EOF#
