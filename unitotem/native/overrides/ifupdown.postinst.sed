# the group is made with groupadd -R at the lowest free GID of SYS_GID_MIN (adduser ignores DPKG_ROOT, as in network-manager)
# the interfaces file and the SysV check are under DPKG_ROOT; deb-systemd-helper and update-rc.d honor DPKG_ROOT themselves
/^MYNAME=/a\
nb_sysgroup() {\
    grep -q "^$1:" "${DPKG_ROOT}/etc/group" && return 0\
    gid=$(awk '$1 == "SYS_GID_MIN" { print $2 }' "${DPKG_ROOT}/etc/login.defs"); gid=${gid:-101}\
    while cut -d: -f3 "${DPKG_ROOT}/etc/group" | grep -qx "$gid"; do gid=$((gid + 1)); done\
    groupadd -R "$DPKG_ROOT" -g "$gid" "$1"\
}
s#addgroup --quiet --system netdev#nb_sysgroup netdev#
s#\[ ! -f /etc/network/interfaces \]#[ ! -f "${DPKG_ROOT}/etc/network/interfaces" ]#
s#> /etc/network/interfaces#> "${DPKG_ROOT}/etc/network/interfaces"#
s#\[ -x "/etc/init.d/networking" \]#[ -x "${DPKG_ROOT}/etc/init.d/networking" ]#
