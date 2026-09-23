require "./camelot"
require "libadwaita"
require "./camelot/gtk/main_loop"
require "./camelot/gtk/link"
require "./camelot/gtk/panel"

# camelot-gtk: the control panel. A libadwaita window over the daemon
# socket, with GTK's main loop driven by Camelot::Events::Pump so that
# Crystal sockets and fibers work alongside the toolkit.
Camelot::Gtk::App.main
