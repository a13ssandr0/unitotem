# the init.d scripts are named with absolute paths: the target tree is ${DPKG_ROOT}
s#"/etc/init.d/#"${DPKG_ROOT}/etc/init.d/#g
