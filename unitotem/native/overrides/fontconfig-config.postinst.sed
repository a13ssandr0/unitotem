# the links of the initial configuration in the target tree; the link targets stay absolute
s#^CONFDIR=/etc/fonts/conf.d#CONFDIR=${DPKG_ROOT}/etc/fonts/conf.d#
s#^LOCALDIR=/usr/local/share/fonts#LOCALDIR=${DPKG_ROOT}/usr/local/share/fonts#
s#if \[ -f /etc/staff-group-for-usr-local \]#if [ -f ${DPKG_ROOT}/etc/staff-group-for-usr-local ]#
s#if \[ -d /etc/fonts\.conf\.d \]#if [ -d ${DPKG_ROOT}/etc/fonts.conf.d ]#
s#rmdir --ignore-fail-on-non-empty /etc/fonts\.conf\.d#rmdir --ignore-fail-on-non-empty ${DPKG_ROOT}/etc/fonts.conf.d#
# debconf answers of the config script (not run by the native build): its detection finds the package's
# 10-sub-pixel-none.conf link (answer Never), and no bitmap link yet (answer false)
/^\. \/usr\/share\/debconf\/confmodule$/a\
db_set fontconfig/hinting_type Native\
db_set fontconfig/hinting_style hintslight\
db_set fontconfig/subpixel_rendering Never\
db_set fontconfig/enable_bitmaps false
