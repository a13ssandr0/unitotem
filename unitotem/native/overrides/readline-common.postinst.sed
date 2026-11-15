# the default inputrc is copied under DPKG_ROOT
s#install_from_default /usr/share/readline/inputrc /etc/inputrc#install_from_default "${DPKG_ROOT}/usr/share/readline/inputrc" "${DPKG_ROOT}/etc/inputrc"#
