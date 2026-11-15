# the config file and its directory in the target tree
s#/etc/python3/debian_config#${DPKG_ROOT}/etc/python3/debian_config#g
s#mkdir /etc/python3#mkdir ${DPKG_ROOT}/etc/python3#
s#\[ -d /etc/python3 \]#[ -d ${DPKG_ROOT}/etc/python3 ]#
# the runtime hooks of the target tree
s#/usr/share/python3/runtime\.d/#${DPKG_ROOT}/usr/share/python3/runtime.d/#g
