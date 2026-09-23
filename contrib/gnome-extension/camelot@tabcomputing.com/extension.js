// Camelot shell helper.
//
// Wayland does not let an ordinary program learn where windows sit on the
// screen or where the pointer is; only the compositor knows. This extension
// runs inside GNOME Shell and answers those two questions over D-Bus, so that
// camelot can turn "the point under the cursor" into "the widget under the
// cursor" by asking the right application in its own window coordinates.
//
// It answers only camelot's own programs (by executable name), and it only
// reports geometry and titles — never contents, never input.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const OBJECT_PATH = '/com/tabcomputing/Camelot';
const IFACE = `
<node>
  <interface name="com.tabcomputing.Camelot.Shell">
    <method name="GetPointer">
      <arg type="i" direction="out" name="x"/>
      <arg type="i" direction="out" name="y"/>
    </method>
    <method name="GetWindows">
      <arg type="s" direction="out" name="json"/>
    </method>
    <method name="WindowAt">
      <arg type="i" direction="in" name="x"/>
      <arg type="i" direction="in" name="y"/>
      <arg type="s" direction="out" name="json"/>
    </method>
    <method name="Probe">
      <arg type="s" direction="out" name="json"/>
    </method>
    <property name="Version" type="u" access="read"/>
  </interface>
</node>`;

// Window types a person can point into.
const POINTABLE = new Set([
    Meta.WindowType.NORMAL, Meta.WindowType.DIALOG, Meta.WindowType.MODAL_DIALOG,
    Meta.WindowType.UTILITY, Meta.WindowType.TOOLBAR, Meta.WindowType.MENU,
    Meta.WindowType.POPUP_MENU, Meta.WindowType.DROPDOWN_MENU,
]);

function rect(r) {
    return {x: r.x, y: r.y, width: r.width, height: r.height};
}

function contains(r, x, y) {
    return x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}

export default class CamelotExtension extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
    }

    disable() {
        this._dbus?.unexport();
        this._dbus = null;
    }

    get Version() {
        return 1;
    }

    // ---- methods ------------------------------------------------------------

    GetPointerAsync(_params, invocation) {
        this._serve(invocation, () => {
            const [x, y] = global.get_pointer();
            return new GLib.Variant('(ii)', [x, y]);
        });
    }

    GetWindowsAsync(_params, invocation) {
        this._serve(invocation, () =>
            new GLib.Variant('(s)', [JSON.stringify(this._windows())]));
    }

    WindowAtAsync([x, y], invocation) {
        this._serve(invocation, () =>
            new GLib.Variant('(s)', [JSON.stringify(this._windowAt(x, y))]));
    }

    // Pointer and the window under it, in one round trip.
    ProbeAsync(_params, invocation) {
        this._serve(invocation, () => {
            const [x, y] = global.get_pointer();
            return new GLib.Variant('(s)', [JSON.stringify({pointer: {x, y}, window: this._windowAt(x, y)})]);
        });
    }

    // ---- geometry -----------------------------------------------------------

    // Visible windows on the active workspace, bottom of the stack first.
    _windows() {
        const workspace = global.workspace_manager.get_active_workspace();
        let windows = global.get_window_actors()
            .map(actor => actor.get_meta_window())
            .filter(w => w && !w.minimized && POINTABLE.has(w.get_window_type()) &&
                         (w.is_on_all_workspaces() || w.located_on_workspace(workspace)));
        windows = global.display.sort_windows_by_stacking(windows);
        return windows.map((w, stack) => ({
            id: w.get_id(),
            pid: w.get_pid(),
            title: w.get_title(),
            wm_class: w.get_wm_class(),
            client: w.get_client_type() === Meta.WindowClientType.WAYLAND ? 'wayland' : 'x11',
            focused: w.has_focus(),
            frame: rect(w.get_frame_rect()),
            buffer: rect(w.get_buffer_rect()),
            stack,
        }));
    }

    // The topmost window whose frame contains (x, y), with the point in its
    // frame and buffer coordinates. null over the desktop or the shell.
    _windowAt(x, y) {
        const hit = this._windows().reverse().find(w => contains(w.frame, x, y));
        if (!hit)
            return null;
        hit.point = {
            frame: {x: x - hit.frame.x, y: y - hit.frame.y},
            buffer: {x: x - hit.buffer.x, y: y - hit.buffer.y},
        };
        return hit;
    }

    // ---- who may ask --------------------------------------------------------

    // Only processes whose executable is named camelot* get an answer. This
    // keeps the information from arbitrary programs on the session bus; it is
    // not a wall against a program that runs as you and renames itself.
    _authorized(invocation) {
        return new Promise(resolve => {
            Gio.DBus.session.call('org.freedesktop.DBus', '/org/freedesktop/DBus',
                'org.freedesktop.DBus', 'GetConnectionUnixProcessID',
                new GLib.Variant('(s)', [invocation.get_sender()]), new GLib.VariantType('(u)'),
                Gio.DBusCallFlags.NONE, -1, null, (connection, result) => {
                    try {
                        const [pid] = connection.call_finish(result).deepUnpack();
                        const exe = GLib.file_read_link(`/proc/${pid}/exe`);
                        resolve(GLib.path_get_basename(exe).startsWith('camelot'));
                    } catch (e) {
                        resolve(false);
                    }
                });
        });
    }

    async _serve(invocation, answer) {
        try {
            if (!await this._authorized(invocation)) {
                invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied',
                    'the camelot extension answers only camelot');
                return;
            }
            invocation.return_value(answer());
        } catch (e) {
            invocation.return_dbus_error('com.tabcomputing.Camelot.Error.Failed', String(e));
        }
    }
}
