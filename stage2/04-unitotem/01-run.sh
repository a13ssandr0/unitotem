#!/bin/bash -e

# UniTotem manager base environment
cp -r files/unitotem "${ROOTFS_DIR}/opt/"
chmod a+x "${ROOTFS_DIR}/opt/unitotem/uniman.py"
install -v -m 777 -d "${ROOTFS_DIR}/opt/unitotem/static/uploaded"
on_chroot << EOF
python3 -m venv /opt/unitotem/env --system-site-packages
source /opt/unitotem/env/bin/activate
pip3 install python-crontab flask flask-httpauth requests validators decorator qrcode PyChromeDevTools waitress pymediainfo ruamel.yaml
deactivate
EOF

install -v -d "${ROOTFS_DIR}/etc/ssl/unitotem"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "${ROOTFS_DIR}/etc/ssl/unitotem/key.pem" -out "${ROOTFS_DIR}/etc/ssl/unitotem/crt.pem" -days 365000 -subj "/C=../ST=./L=./O=a13ssandr0/OU=UniTotem/CN=UniTotem/emailAddress=."
cat ${ROOTFS_DIR}/etc/ssl/unitotem/{crt,key}.pem > "${ROOTFS_DIR}/etc/ssl/unitotem.pem"
rm -r "${ROOTFS_DIR}/etc/ssl/unitotem"
chmod 0600 "${ROOTFS_DIR}/etc/ssl/unitotem.pem"

install -v -m 644 files/{start-xorg,unitotem-manager}.service "${ROOTFS_DIR}/etc/systemd/system/"
on_chroot << EOF
adduser unitotem
EOF
on_chroot << EOF
systemctl enable start-xorg.service
systemctl enable unitotem-manager.service
EOF

install -v files/haproxy.cfg "${ROOTFS_DIR}/etc/haproxy"
install -v -m 755 files/xinitrc "${ROOTFS_DIR}/etc/X11/xinit/"