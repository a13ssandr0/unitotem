# the interpreter runs py_compile.py on the host: byte-compile the target files natively (nb-pycompile, see nb-shim)
s#/usr/bin/python3\.13 -E -S\( -O\)\? /usr/lib/python3\.13/py_compile\.py#nb-pycompile#
# the file list comes from the target's dpkg database; state and directories under DPKG_ROOT
s#dpkg -L libpython3\.13-minimal:arm64#dpkg --admindir="${DPKG_ROOT}/var/lib/dpkg" -L libpython3.13-minimal:arm64#
s#/usr/local/lib/python3\.13#${DPKG_ROOT}/usr/local/lib/python3.13#g
s#/var/lib/python\([ /]\)#${DPKG_ROOT}/var/lib/python\1#g
s#/etc/python3\.13/sysconfig\.cfg#${DPKG_ROOT}/etc/python3.13/sysconfig.cfg#
s#/etc/python3\.13/sitecustomize\.py#${DPKG_ROOT}/etc/python3.13/sitecustomize.py#g
s#/usr/lib/python3\.13/sitecustomize\.py#${DPKG_ROOT}/usr/lib/python3.13/sitecustomize.py#g
s#/usr/share/python/debian_defaults#${DPKG_ROOT}/usr/share/python/debian_defaults#
s#/etc/python/debian_config#${DPKG_ROOT}/etc/python/debian_config#g
s#/etc/staff-group-for-usr-local#${DPKG_ROOT}/etc/staff-group-for-usr-local#g
# the runtime marker of a new installation: the original preinst writes it, but dpkg runs the new preinst before the
# overrides are applied, so it is written here (the postinst keeps it: no byte-compile hook runs, see bc below)
/^set -e$/a\
if [ "$1" = configure ] \&\& [ -z "$2" ]; then mkdir -p ${DPKG_ROOT}/var/lib/python \&\& touch ${DPKG_ROOT}/var/lib/python/python3.13_installed; fi
