import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const IFACE = `
<node>
  <interface name="dev.timely.Focus">
    <method name="Get">
      <arg type="s" direction="out" name="appId"/>
      <arg type="s" direction="out" name="appName"/>
      <arg type="u" direction="out" name="idleMs"/>
      <arg type="b" direction="out" name="locked"/>
    </method>
  </interface>
</node>`;

export default class TimelyFocusExtension extends Extension {
    enable() {
        this._impl = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._impl.export(Gio.DBus.session, '/dev/timely/Focus');
        this._owner = Gio.bus_own_name_on_connection(
            Gio.DBus.session, 'dev.timely.Focus', Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        this._impl?.unexport();
        this._impl = null;
        if (this._owner)
            Gio.bus_unown_name(this._owner);
        this._owner = 0;
    }

    Get() {
        let id = '';
        let name = '';
        const win = global.display.focus_window;
        if (win) {
            const app = Shell.WindowTracker.get_default().get_window_app(win);
            if (app) {
                id = app.get_id() ?? '';
                name = app.get_name() ?? '';
            }
            if (!id) {
                id = win.get_wm_class() ?? '';
                name = id;
            }
        }
        let idle = 0;
        try {
            idle = global.backend.get_core_idle_monitor().get_idletime();
        } catch (_) {}
        const locked = Boolean(Main.sessionMode.isLocked || Main.screenShield?.locked);
        return [id, name, Math.min(idle, 0xffffffff), locked];
    }
}
