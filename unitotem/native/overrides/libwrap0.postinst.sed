# the default access files are created under DPKG_ROOT
s#\[ ! -e /etc/hosts\.allow \]#[ ! -e "${DPKG_ROOT}/etc/hosts.allow" ]#
s#cat > /etc/hosts\.allow <<EOF#cat > "${DPKG_ROOT}/etc/hosts.allow" <<EOF#
s#\[ ! -e /etc/hosts\.deny \]#[ ! -e "${DPKG_ROOT}/etc/hosts.deny" ]#
s#cat > /etc/hosts\.deny <<EOF#cat > "${DPKG_ROOT}/etc/hosts.deny" <<EOF#
