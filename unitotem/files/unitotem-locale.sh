# Locale for login shells. sshd runs without PAM, so pam_env does not read /etc/default/locale and a session would start
# in the C locale (btop and other programs refuse to run without UTF-8).
if [ -z "${LANG:-}" ] && [ -r /etc/default/locale ]; then
    set -a
    . /etc/default/locale
    set +a
fi
