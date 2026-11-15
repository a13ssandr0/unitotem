# the absolute paths name the builder's root: the target tree is ${DPKG_ROOT}; the systemd reload runs only on a running system
s#chmod 0700 /var/lib/NetworkManager#chmod 0700 "${DPKG_ROOT}/var/lib/NetworkManager"#
s#NIF=/etc/network/interfaces#NIF="${DPKG_ROOT}/etc/network/interfaces"#
s#if \[ -d /run/systemd/system \]; then#if [ -z "${DPKG_ROOT:-}" ] \&\& [ -d /run/systemd/system ]; then#
# adduser ignores DPKG_ROOT: the group is made with groupadd -R at the lowest free GID of SYS_GID_MIN (as adduser does)
/^case "\$1" in/i\
nb_sysgroup() {\
    grep -q "^$1:" "${DPKG_ROOT}/etc/group" && return 0\
    gid=$(awk '$1 == "SYS_GID_MIN" { print $2 }' "${DPKG_ROOT}/etc/login.defs"); gid=${gid:-101}\
    while cut -d: -f3 "${DPKG_ROOT}/etc/group" | grep -qx "$gid"; do gid=$((gid + 1)); done\
    groupadd -R "$DPKG_ROOT" -g "$gid" "$1"\
}\

s#addgroup --quiet --system netdev#nb_sysgroup netdev#
