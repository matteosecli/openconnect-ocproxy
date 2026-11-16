#!/bin/sh
# Installs (or updates) the OpenConnect Proxy login notifier as a systemd --user service.
# Clickable notifications need gdbus (GLib) and dbus-monitor (D-Bus), plus stdbuf (coreutils) and a
# terminal emulator; all ship with the usual desktop installs. Without gdbus it falls back to
# notify-send (libnotify-bin on Debian/Ubuntu) and shows the login command as text.
# Usage: sh install.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lib="$HOME/.local/lib/openconnect-ocproxy-notifier"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/openconnect-ocproxy-notifier"

command -v systemctl >/dev/null 2>&1 || { echo 'systemd --user is required.' >&2; exit 1; }
for tool in gdbus dbus-monitor stdbuf; do
    command -v "$tool" >/dev/null 2>&1 || echo "Note: $tool not found; notifications will not be clickable." >&2
done

mkdir -p "$lib" "$unit_dir" "$config_dir"
install -m 0755 "$here/vpn-notifier.sh" "$lib/vpn-notifier.sh"
install -m 0755 "$here/../common/vpn-state.sh" "$lib/vpn-state.sh"
install -m 0644 "$here/../VERSION" "$lib/VERSION"
install -m 0644 "$here/openconnect-ocproxy-notifier.service" "$unit_dir/openconnect-ocproxy-notifier.service"

if [ ! -e "$config_dir/config" ]; then
    cat > "$config_dir/config" <<'EOF'
# Edit and restart the service to apply (systemctl --user restart openconnect-ocproxy-notifier).
#CONTAINER_NAME=openconnect-ocproxy
#REMINDER_MINUTES=30
#TERMINAL_APP=gnome-terminal
EOF
fi

systemctl --user daemon-reload
systemctl --user enable openconnect-ocproxy-notifier.service
# restart, not start: rerunning this script is how an update takes effect.
systemctl --user restart openconnect-ocproxy-notifier.service
echo "Installed version $(cat "$lib/VERSION") and started. Check right away with:"
echo "  systemctl --user kill -s USR1 openconnect-ocproxy-notifier.service"
echo "Logs: journalctl --user -u openconnect-ocproxy-notifier -f"
