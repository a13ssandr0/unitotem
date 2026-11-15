# /etc/default/keyboard in the target tree, from the template file of the target
s#^CONFIGFILE=/etc/default/keyboard#CONFIGFILE=${DPKG_ROOT}/etc/default/keyboard#
s#cat /usr/share/console-setup/keyboard#cat ${DPKG_ROOT}/usr/share/console-setup/keyboard#
# debconf answers: the defaults of the C locale (the config script does not run in the native build)
/^\. \/usr\/share\/debconf\/confmodule$/a\
db_set keyboard-configuration/modelcode pc105\
db_set keyboard-configuration/layoutcode us\
db_set keyboard-configuration/variantcode ""\
db_set keyboard-configuration/optionscode ""
