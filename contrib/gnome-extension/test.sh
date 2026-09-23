#!/usr/bin/env bash
# Exercise the extension and camelot's screen-point resolution in a throwaway
# headless GNOME Shell: its own D-Bus session, settings, runtime dir and
# extension directory, a 1600x900 virtual monitor, and one GTK window to point
# at. Nothing touches the running desktop. Usage: contrib/gnome-extension/test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
camelot=${CAMELOT:-$here/../../bin/camelot}
T=$(mktemp -d /tmp/camelot-shell-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data/gnome-shell/extensions" "$T/config/glib-2.0/settings" "$T/run"
chmod 700 "$T/run"
cp -r "$here/camelot@tabcomputing.com" "$T/data/gnome-shell/extensions/"
cat > "$T/config/glib-2.0/settings/keyfile" <<'KEYS'
[org/gnome/shell]
enabled-extensions=['camelot@tabcomputing.com']
disable-user-extensions=false
welcome-dialog-last-shown-version='999'
KEYS
cp "$(command -v gdbus)" "$T/camelot-probe" # a name the extension will answer
cat > "$T/window.js" <<'JS'
import Gtk from 'gi://Gtk?version=4.0';
import GLib from 'gi://GLib';
Gtk.init();
const w = new Gtk.Window({title: 'camelot probe', default_width: 400, default_height: 300});
w.set_child(new Gtk.Button({label: 'Point at me'}));
w.present();
new GLib.MainLoop(null, false).run();
JS
cat > "$T/inner.sh" <<INNER
set -u
export GSETTINGS_BACKEND=keyfile XDG_CONFIG_HOME=$T/config XDG_DATA_HOME=$T/data XDG_RUNTIME_DIR=$T/run CAMELOT_LOCAL=1
gnome-shell --headless --wayland --no-x11 --virtual-monitor 1600x900 --wayland-display camelot-test >"$T/shell.log" 2>&1 &
for i in \$(seq 1 40); do
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell 2>/dev/null | grep -q true && break
  sleep 0.5
done
# The isolated bus cannot activate the a11y registry through systemd.
/usr/lib/at-spi2-registryd --use-gnome-session >/dev/null 2>&1 &
sleep 2
WAYLAND_DISPLAY=camelot-test GDK_BACKEND=wayland gjs -m "$T/window.js" >/dev/null 2>&1 &
sleep 3
quiet() { grep -vE "dbus-daemon|dbind|^\\\$" || true; }
C="--session --dest org.gnome.Shell --object-path /com/tabcomputing/Camelot --method com.tabcomputing.Camelot.Shell"
echo "extension: \$(gnome-extensions info camelot@tabcomputing.com 2>&1 | grep -o 'State: .*')"
echo "compositor: \$("$T/camelot-probe" call \$C.WindowAt 800 450 | grep -o '"frame":{[^}]*}' | head -1)"
echo "at 800 450 --screen: \$($camelot at 800 450 --screen 2>&1 | quiet)"
echo "at 100 100 --screen: \$($camelot at 100 100 --screen 2>&1 | quiet)"
echo "plain gdbus: \$(gdbus call \$C.GetPointer 2>&1 | grep -o 'AccessDenied' || echo 'ANSWERED — guard broken')"
INNER
timeout 120 dbus-run-session -- bash "$T/inner.sh" 2>/dev/null
