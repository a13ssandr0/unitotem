# the file list comes from the target's dpkg database (the builder's has no arm64 packages), and the byte code is
# written by nb-pycompile in the target tree (nb-shim) instead of the builder's /usr/bin/python3.13
s#dpkg -L libpython3\.13-stdlib:arm64#dpkg --admindir="${DPKG_ROOT}/var/lib/dpkg" -L libpython3.13-stdlib:arm64#
s#/usr/bin/python3\.13 -E -S\( -O\)\? /usr/lib/python3\.13/py_compile\.py#nb-pycompile#
