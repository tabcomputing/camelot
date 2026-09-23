require "./link"

module Camelot
  module Gtk
    # The control panel. The front page is a switchboard: what is being
    # recorded, one switch per capability, with the daemon itself as the
    # first row. The activity log and the ignore list are pages behind it —
    # the user knows what they are doing; the record is there when wanted.
    class Panel
      RETENTIONS = [
        {"5 minutes", 5.minutes}, {"15 minutes", 15.minutes}, {"30 minutes", 30.minutes},
        {"1 hour", 1.hour}, {"4 hours", 4.hours}, {"1 day", 1.day},
      ]
      WINDOWS = [{"last minute", 60}, {"last 5 minutes", 300}, {"last 30 minutes", 1800}, {"last 2 hours", 7200}]

      @window : Adw::ApplicationWindow
      @toasts : Adw::ToastOverlay
      @nav : Adw::NavigationView
      # switchboard rows
      @daemon_row : Adw::SwitchRow
      @recording_row : Adw::SwitchRow
      @text_row : Adw::SwitchRow
      @retention_row : Adw::ComboRow
      @log_row : Adw::SwitchRow
      @a11y_row : Adw::SwitchRow
      @ignore_nav : Adw::ActionRow
      @activity_nav : Adw::ActionRow
      # activity page
      @activity_list : ::Gtk::ListBox
      @activity_empty : Adw::ActionRow
      @digest = History::Digest.new
      @rows = {} of History::Entry => Adw::ActionRow
      @window_secs = 300
      # ignore page
      @ignore_group : Adw::PreferencesGroup
      @ignore_rows = [] of ::Gtk::Widget
      @syncing = false
      # shelf
      @shelf_picture : ::Gtk::Picture
      @shelf_empty : ::Gtk::Label
      @shelf_caption : ::Gtk::Label
      @shelf_drag : ::Gtk::DragSource
      @pick_button : ::Gtk::Button
      @copy_button : ::Gtk::Button
      @discard_button : ::Gtk::Button
      @shelf_monitor : Gio::FileMonitor?
      @picking = false

      def initialize(app : Adw::Application, @link : Link, @config : Config)
        @window = Adw::ApplicationWindow.new(app)
        @window.title = "Camelot"
        @window.set_default_size(480, 720)
        @toasts = Adw::ToastOverlay.new
        @nav = Adw::NavigationView.new

        @daemon_row = Adw::SwitchRow.new
        @recording_row = Adw::SwitchRow.new
        @text_row = Adw::SwitchRow.new
        @retention_row = Adw::ComboRow.new
        @log_row = Adw::SwitchRow.new
        @a11y_row = Adw::SwitchRow.new
        @ignore_nav = Adw::ActionRow.new
        @activity_nav = Adw::ActionRow.new
        @activity_list = ::Gtk::ListBox.new
        @activity_empty = Adw::ActionRow.new
        @ignore_group = Adw::PreferencesGroup.new
        @shelf_picture = ::Gtk::Picture.new
        @shelf_empty = ::Gtk::Label.new("")
        @shelf_caption = ::Gtk::Label.new("")
        @shelf_drag = ::Gtk::DragSource.new
        @pick_button = ::Gtk::Button.new_with_label("Pick…")
        @copy_button = ::Gtk::Button.new_with_label("Copy")
        @discard_button = ::Gtk::Button.new_with_label("Discard")

        @nav.add(page("Camelot", switchboard))
        @toasts.child = @nav
        @window.content = @toasts

        # The link calls these from its own fiber; GTK is touched on the loop's turn.
        @link.on_change = ->(what : Symbol) { MainLoop.invoke { changed(what) }; nil }
        @link.on_event = ->(e : Events::Event) { MainLoop.invoke { fold(e) }; nil }
        refresh_state
        rebuild_activity
        rebuild_ignore
        watch_shelf
        refresh_shelf
      end

      def present : Nil
        @window.present
      end

      private def page(title : String, content : ::Gtk::Widget) : Adw::NavigationPage
        view = Adw::ToolbarView.new
        view.add_top_bar(Adw::HeaderBar.new)
        view.content = content
        Adw::NavigationPage.new(child: view, title: title)
      end

      # ---- Switchboard ----------------------------------------------------------

      private def switchboard : ::Gtk::Widget
        pg = Adw::PreferencesPage.new
        pg.add(shelf_group)

        service = Adw::PreferencesGroup.new
        @daemon_row.title = "Background service"
        @daemon_row.notify_signal["active"].connect { toggle_daemon }
        service.add(@daemon_row)
        pg.add(service)

        rec = Adw::PreferencesGroup.new
        rec.title = "Recording"
        rec.description = "In memory, readable only by you, gone when the service stops."

        @recording_row.title = "Activity"
        @recording_row.subtitle = "Window switches, focus changes, edits"
        @recording_row.notify_signal["active"].connect { toggle_recording }
        rec.add(@recording_row)

        @text_row.title = "Typed text"
        @text_row.subtitle = "Off: which field and how much, not what"
        @text_row.active = @config.text
        @text_row.notify_signal["active"].connect { save { @config.text = @text_row.active? } }
        rec.add(@text_row)

        @retention_row.title = "Keep for"
        labels = RETENTIONS.map(&.[0])
        current = RETENTIONS.index { |_, span| span == @config.retention }
        unless current
          labels << Config::Duration.format(@config.retention)
          current = labels.size - 1
        end
        @retention_row.model = ::Gtk::StringList.new(labels)
        @retention_row.selected = current.to_u32
        @retention_row.notify_signal["selected"].connect do
          i = @retention_row.selected.to_i
          save { @config.retention = RETENTIONS[i][1] } if i < RETENTIONS.size
        end
        rec.add(@retention_row)

        @log_row.title = "Durable log"
        @log_row.subtitle = "Append every event to #{Config.new.tap(&.log = true).log_dir}"
        @log_row.active = @config.log != false
        @log_row.notify_signal["active"].connect { save { @config.log = @log_row.active? } }
        rec.add(@log_row)
        pg.add(rec)

        access = Adw::PreferencesGroup.new
        access.title = "Access"
        @a11y_row.title = "Browser accessibility"
        @a11y_row.subtitle = "Turned on when the service starts; browsers need it at their start"
        @a11y_row.active = @config.accessibility
        @a11y_row.notify_signal["active"].connect { save { @config.accessibility = @a11y_row.active? } }
        access.add(@a11y_row)

        @ignore_nav.title = "Ignored applications"
        @ignore_nav.activatable = true
        @ignore_nav.add_suffix(::Gtk::Image.new_from_icon_name("go-next-symbolic"))
        @ignore_nav.activated_signal.connect { @nav.push(page("Ignored applications", ignore_page)) }
        access.add(@ignore_nav)
        pg.add(access)

        more = Adw::PreferencesGroup.new
        @activity_nav.title = "Activity log"
        @activity_nav.activatable = true
        @activity_nav.add_suffix(::Gtk::Image.new_from_icon_name("go-next-symbolic"))
        @activity_nav.activated_signal.connect { @nav.push(page("Activity", activity_page)) }
        more.add(@activity_nav)
        pg.add(more)

        pg
      end

      # ---- Shelf -----------------------------------------------------------------

      # The one thing you chose to show an AI. Drag the picture anywhere that
      # takes images, copy it, or tell an agent to look at your shelf.
      private def shelf_group : Adw::PreferencesGroup
        group = Adw::PreferencesGroup.new
        group.title = "Shelf"
        group.description = "What you choose to show an AI. Drag it into a chat or terminal, copy it, " \
                            "or ask an agent to look at your shelf."
        @pick_button.add_css_class("suggested-action")
        @pick_button.valign = ::Gtk::Align::Center
        @pick_button.tooltip_text = "Choose a window or region to put on the shelf"
        @pick_button.clicked_signal.connect { pick }
        group.header_suffix = @pick_button

        @shelf_picture.content_fit = ::Gtk::ContentFit::Contain
        @shelf_picture.can_shrink = true
        @shelf_picture.height_request = 200
        @shelf_picture.tooltip_text = "Drag me somewhere"
        @shelf_picture.add_controller(@shelf_drag)
        @shelf_drag.drag_begin_signal.connect do
          if (paintable = @shelf_picture.paintable)
            @shelf_drag.set_icon(paintable, 0, 0)
          end
        end
        group.add(@shelf_picture)

        @shelf_empty.label = "Nothing on the shelf. Pick a window or region to share it."
        @shelf_empty.add_css_class("dim-label")
        @shelf_empty.margin_top = 24
        @shelf_empty.margin_bottom = 24
        group.add(@shelf_empty)

        row = ::Gtk::Box.new(::Gtk::Orientation::Horizontal, 6)
        row.margin_top = 6
        @shelf_caption.add_css_class("dim-label")
        @shelf_caption.xalign = 0
        @shelf_caption.hexpand = true
        row.append(@shelf_caption)
        @copy_button.tooltip_text = "Copy the image to the clipboard"
        @copy_button.clicked_signal.connect { copy_shelf }
        row.append(@copy_button)
        @discard_button.tooltip_text = "Empty the shelf"
        @discard_button.clicked_signal.connect do
          Shelf.clear
          refresh_shelf
        end
        row.append(@discard_button)
        group.add(row)
        group
      end

      # The panel leaves the stage while you pick, so it is not in the way,
      # and comes back holding what you picked. The capture waits in its own
      # fiber: the portal answers through the GLib loop this handler is
      # running on, so waiting here would wait forever.
      private def pick : Nil
        return if @picking
        @picking = true
        @pick_button.sensitive = false
        # Wayland will not let a window raise itself later on its own say-so;
        # it needs an activation token, and only an app with focus and a
        # fresh click can get one. So take it now and spend it after.
        debug = ENV["CAMELOT_DEBUG"]?
        STDERR.puts "pick: requesting activation token" if debug
        token = begin
          @window.display.app_launch_context.startup_notify_id(nil, nil)
        rescue
          nil
        end
        STDERR.puts "pick: token #{token.inspect}" if debug
        spawn(name: "camelot-gtk-pick") do
          failure = nil.as(String?)
          begin
            MainLoop.invoke { @window.minimize }
            sleep 400.milliseconds # let the panel get out of the way
            STDERR.puts "pick: capturing" if debug
            Shelf.put(Capture.shot(interactive: !ENV["CAMELOT_PICK_NONINTERACTIVE"]?), "pick")
            STDERR.puts "pick: shelved" if debug
          rescue Capture::Cancelled
            # you closed the picker: nothing to report
          rescue ex : Capture::Error
            STDERR.puts "pick: capture failed: #{ex.message}" if debug
            failure = ex.message.to_s
          ensure
            MainLoop.invoke do
              STDERR.puts "pick: presenting" if debug
              @window.startup_id = token if token
              @window.present
              STDERR.puts "pick: presented" if debug
              @picking = false
              @pick_button.sensitive = true
              refresh_shelf
              failure.try { |m| toast(m) }
            end
          end
        end
      end

      private def copy_shelf : Nil
        item = Shelf.item || return
        # A texture, so the clipboard can offer PNG as well as JPEG to
        # whatever pastes it.
        texture = Gdk::Texture.new_from_filename(item.path)
        @window.clipboard.content = Gdk::ContentProvider.new_for_value(texture)
        toast("Copied — paste it anywhere")
      rescue ex
        toast("Could not copy: #{ex.message}")
      end

      private def refresh_shelf : Nil
        item = Shelf.item
        @copy_button.sensitive = !item.nil?
        @discard_button.sensitive = !item.nil?
        if item
          begin
            @shelf_picture.paintable = Gdk::Texture.new_from_filename(item.path)
          rescue
            @shelf_picture.paintable = nil
          end
          @shelf_picture.visible = true
          @shelf_empty.visible = false
          @shelf_caption.label = "#{item.source} · #{item.width}×#{item.height} · #{item.time.to_s("%H:%M")}"
          @shelf_drag.content = drag_content(item)
        else
          @shelf_picture.paintable = nil
          @shelf_picture.visible = false
          @shelf_empty.visible = true
          @shelf_caption.label = ""
          @shelf_drag.content = nil
        end
      end

      # A dragged shelf item is a file (terminals insert the path, browsers
      # and chats upload it), and plain text of that path for anything that
      # only takes text.
      private def drag_content(item : Shelf::Item) : Gdk::ContentProvider
        uri = "file://#{item.path}\r\n"
        members = [
          Gdk::ContentProvider.new_for_bytes("text/uri-list", GLib::Bytes.new(uri.to_unsafe, uri.bytesize)),
          Gdk::ContentProvider.new_for_bytes("text/plain;charset=utf-8", GLib::Bytes.new(item.path.to_unsafe, item.path.bytesize)),
        ]
        # new_union takes ownership of its members, but the generated binding
        # passes them without a reference of their own; when our wrappers are
        # collected the union is left holding freed objects. Give it its own.
        members.each { |m| LibGObject.g_object_ref(m.to_unsafe) }
        Gdk::ContentProvider.new_union(members)
      end

      # The shelf changes from the command line too (`camelot shot --pick
      # --shelf`); inotify tells us, no timers.
      private def watch_shelf : Nil
        Dir.mkdir_p(Shelf.dir)
        File.chmod(Shelf.dir, 0o700)
        mon = Gio::File.new_for_path(Shelf.dir).monitor_directory(Gio::FileMonitorFlags::None, nil)
        mon.changed_signal.connect do |file, _other, _kind|
          # (gi-crystal hands the basename back as a Path, not a String)
          refresh_shelf if file.basename.to_s == "shelf.json"
        end
        @shelf_monitor = mon
      rescue ex
        STDERR.puts "camelot-gtk: cannot watch the shelf: #{ex.message}"
      end

      # ---- Activity page --------------------------------------------------------

      private def activity_page : ::Gtk::Widget
        pg = Adw::PreferencesPage.new
        group = Adw::PreferencesGroup.new
        range = ::Gtk::DropDown.new_from_strings(WINDOWS.map(&.[0]))
        range.selected = WINDOWS.index { |_, secs| secs == @window_secs }.try(&.to_u32) || 1_u32
        range.valign = ::Gtk::Align::Center
        range.notify_signal["selected"].connect do
          @window_secs = WINDOWS[range.selected][1]
          rebuild_activity
        end
        group.title = "What you've been doing"
        group.header_suffix = range
        @activity_list.parent.try { |p| p.as(Adw::PreferencesGroup).remove(@activity_list) }
        @activity_list.add_css_class("boxed-list")
        @activity_list.selection_mode = ::Gtk::SelectionMode::None
        group.add(@activity_list)
        pg.add(group)
        pg
      end

      # One pushed event: fold it, then touch exactly one row.
      private def fold(e : Events::Event) : Nil
        cutoff = Time.local - @window_secs.seconds
        @digest.prune(cutoff).each { |old| @rows.delete(old).try { |row| @activity_list.remove(row) } }
        if touched = @digest.add(e)
          entry, how = touched
          case how
          when :appended
            row = row_for(entry)
            @rows[entry] = row
            @activity_list.prepend(row) # newest on top
          when :updated
            @rows[entry]?.try { |row| row.subtitle = subtitle_for(entry) }
          end
        end
        placeholder
        refresh_counts
      end

      # Re-derive the list from the local history: on a window change or
      # a (re)connection. Everything else goes through `fold`.
      private def rebuild_activity : Nil
        @rows.each_value { |row| @activity_list.remove(row) }
        @rows.clear
        @digest = History::Digest.new
        if @link.connected?
          @link.history.since(Time.local - @window_secs.seconds).each { |e| @digest.add(e) }
          @digest.entries.each do |entry|
            row = row_for(entry)
            @rows[entry] = row
            @activity_list.prepend(row)
          end
        end
        placeholder
      end

      private def placeholder : Nil
        if @rows.empty?
          @activity_empty.title = @link.connected? ? "No activity in this window" : "Start the service to see activity"
          @activity_empty.add_css_class("dim-label")
          @activity_list.append(@activity_empty) unless @activity_empty.parent
        elsif @activity_empty.parent
          @activity_list.remove(@activity_empty)
        end
      end

      private def row_for(e : History::Entry) : Adw::ActionRow
        row = Adw::ActionRow.new
        widget = e.name ? "#{e.role} “#{e.name}”" : (e.role || "?")
        row.title = escape("#{e.app}: #{widget}")
        row.subtitle = subtitle_for(e)
        icon = case e.kind
               when "window" then "window-symbolic"
               when "focus"  then "input-keyboard-symbolic"
               when "edit"   then "document-edit-symbolic"
               when "output" then "utilities-terminal-symbolic"
               else               "document-open-symbolic"
               end
        row.add_prefix(::Gtk::Image.new_from_icon_name(icon))
        row
      end

      private def subtitle_for(e : History::Entry) : String
        escape(String.build do |s|
          s << e.time.to_s("%H:%M:%S") << "  " << e.kind
          s << " ×" << e.count if e.count > 1
          if (u = e.until) && e.count > 1
            s << " over " << (u - e.time).total_seconds.round(1) << "s"
          end
          if t = e.text
            s << "  “" << t << "”"
          end
        end)
      end

      # ---- Ignore page ----------------------------------------------------------

      private def ignore_page : ::Gtk::Widget
        pg = Adw::PreferencesPage.new
        @ignore_group.parent.try { |p| p.as(Adw::PreferencesPage).remove(@ignore_group) }
        @ignore_group.description = "Never snapshotted, never recorded. Case-insensitive; * matches anything."
        pg.add(@ignore_group)

        add = Adw::PreferencesGroup.new
        entry = Adw::EntryRow.new
        entry.title = "Add a name or pattern"
        entry.show_apply_button = true
        entry.apply_signal.connect do
          pattern = entry.text.strip
          unless pattern.empty? || @config.ignore.includes?(pattern)
            save { @config.ignore << pattern }
            rebuild_ignore
          end
          entry.text = ""
        end
        add.add(entry)
        pick = Adw::ActionRow.new
        pick.title = "Choose a running application…"
        pick.activatable = true
        pick.add_prefix(::Gtk::Image.new_from_icon_name("list-add-symbolic"))
        pick.activated_signal.connect { pick_application }
        add.add(pick)
        pg.add(add)
        pg
      end

      private def rebuild_ignore : Nil
        @ignore_rows.each { |r| @ignore_group.remove(r) }
        @ignore_rows.clear
        @config.ignore.each do |pattern|
          row = Adw::ActionRow.new
          row.title = escape(pattern)
          remove = ::Gtk::Button.new_from_icon_name("user-trash-symbolic")
          remove.valign = ::Gtk::Align::Center
          remove.add_css_class("flat")
          remove.clicked_signal.connect do
            save { @config.ignore.delete(pattern) }
            rebuild_ignore
          end
          row.add_suffix(remove)
          @ignore_group.add(row)
          @ignore_rows << row
        end
        if @config.ignore.empty?
          row = Adw::ActionRow.new
          row.title = "Nothing ignored"
          row.add_css_class("dim-label")
          @ignore_group.add(row)
          @ignore_rows << row
        end
        @ignore_nav.subtitle = @config.ignore.empty? ? "None" : escape(@config.ignore.join(", "))
      end

      private def pick_application : Nil
        apps = if answer = Client.call("apps", JSON.parse(%({"format":"json"})))
                 reply, err = answer
                 err ? [] of String : JSON.parse(reply).as_a.map(&.["name"].as_s)
               else
                 A11y.applications.map { |a| A11y.safe("") { a.name } }
               end
        apps = apps.reject(&.empty?).uniq.sort
        dialog = Adw::AlertDialog.new("Ignore an application", nil)
        dialog.add_response("cancel", "Cancel")
        list = ::Gtk::ListBox.new
        list.add_css_class("boxed-list")
        list.selection_mode = ::Gtk::SelectionMode::None
        apps.each do |name|
          row = Adw::ActionRow.new
          row.title = escape(name)
          row.activatable = true
          list.append(row)
        end
        list.row_activated_signal.connect do |row|
          name = apps[row.index]
          unless @config.ignore.includes?(name)
            save { @config.ignore << name }
            rebuild_ignore
          end
          dialog.close
        end
        scroller = ::Gtk::ScrolledWindow.new
        scroller.child = list
        scroller.propagate_natural_height = true
        scroller.max_content_height = 400
        dialog.extra_child = scroller
        dialog.present(@window)
      end

      # ---- state & actions ------------------------------------------------------

      private def changed(what : Symbol) : Nil
        STDERR.puts "camelot-gtk: change: #{what}" if ENV["CAMELOT_DEBUG"]?
        refresh_state
        rebuild_activity if what == :connected || what == :disconnected
      end

      private def refresh_state : Nil
        @syncing = true
        st = @link.status
        @daemon_row.active = !st.nil?
        if st
          @daemon_row.subtitle = "Running since #{st.started.to_s("%H:%M")} · pid #{st.pid}"
          @recording_row.sensitive = true
          @recording_row.active = !@link.paused?
          @recording_row.subtitle = if p = st.paused_since
                                      "Paused since #{p.to_s("%H:%M")}"
                                    else
                                      "Window switches, focus changes, edits"
                                    end
          @log_row.subtitle = st.log_dir ? "Logging to #{st.log_dir} since #{st.log_since.try(&.to_s("%H:%M"))}" : "Append every event to #{Config.new.tap(&.log = true).log_dir}"
        else
          @daemon_row.subtitle = @link.unit_installed? ? "Stopped — nothing is recorded" : "Stopped — nothing is recorded (no systemd unit; will run as a child)"
          @recording_row.sensitive = false
          @recording_row.active = false
          @recording_row.subtitle = "Window switches, focus changes, edits"
        end
        refresh_counts
        @syncing = false
      end

      private def refresh_counts : Nil
        if st = @link.status
          @activity_nav.subtitle = "#{@link.history.count} events in the last #{Config::Duration.format(st.retention_seconds.seconds)}"
        else
          @activity_nav.subtitle = "Service not running"
        end
      end

      private def toggle_daemon : Nil
        return if @syncing
        error = @daemon_row.active? ? @link.start_daemon : @link.stop_daemon
        if error
          toast(error)
          refresh_state
        end
      end

      private def toggle_recording : Nil
        return if @syncing || !@link.connected?
        @recording_row.active? ? @link.resume : @link.pause
      end

      # Persist a config change and tell the daemon.
      private def save(&) : Nil
        yield
        @config.save
        Config.current = @config
        if @link.connected?
          if error = @link.reload
            toast("Service rejected the config: #{error}")
          end
        end
      rescue ex : File::Error
        toast("Could not save #{Config.path}: #{ex.message}")
      end

      private def toast(message : String) : Nil
        @toasts.add_toast(Adw::Toast.new(title: message))
      end

      private def escape(text : String) : String
        text.gsub("&", "&amp;").gsub("<", "&lt;")
      end
    end

    class App
      def self.main : Nil
        GLib.prgname = "camelot-gtk"
        GLib.application_name = "Camelot" # what the accessibility bus calls us
        app = Adw::Application.new("com.tabcomputing.Camelot", Gio::ApplicationFlags::None)
        stop = Channel(Nil).new(1)
        link = Link.new
        config = Config.load

        app.activate_signal.connect do
          Panel.new(app, link, config).present
          link.start
        end
        app.window_removed_signal.connect do
          select
          when stop.send(nil)
          else
          end
        end
        Process.on_terminate do
          select
          when stop.send(nil)
          else
          end
        end

        app.register(nil)
        app.activate
        Events::Pump.new.run(stop: stop)
      end
    end
  end
end
