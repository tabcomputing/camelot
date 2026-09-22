require "./link"

module Camelot
  module Gtk
    # The control panel window: a status header with the recording
    # switch, an Activity page fed by the daemon's push stream, and a
    # Settings page that writes the config file and reloads the daemon.
    class Panel
      RETENTIONS = [
        {"5 minutes", 5.minutes}, {"15 minutes", 15.minutes}, {"30 minutes", 30.minutes},
        {"1 hour", 1.hour}, {"4 hours", 4.hours}, {"1 day", 1.day},
      ]
      WINDOWS = [{"last minute", 60}, {"last 5 minutes", 300}, {"last 30 minutes", 1800}, {"last 2 hours", 7200}]

      @window : Adw::ApplicationWindow
      @toasts : Adw::ToastOverlay
      @banner : Adw::Banner
      @recording : ::Gtk::Switch
      @status_label : ::Gtk::Label
      @activity_group : Adw::PreferencesGroup
      @activity_list : ::Gtk::ListBox
      @activity_empty : Adw::ActionRow
      @digest = History::Digest.new
      @rows = {} of History::Entry => Adw::ActionRow
      @window_secs = 300
      @ignore_group : Adw::PreferencesGroup
      @ignore_rows = [] of ::Gtk::Widget
      @daemon_row : Adw::ActionRow
      @daemon_button : ::Gtk::Button
      @syncing = false

      def initialize(app : Adw::Application, @link : Link, @config : Config)
        @window = Adw::ApplicationWindow.new(app)
        @window.title = "Camelot"
        @window.set_default_size(520, 680)
        @toasts = Adw::ToastOverlay.new

        # ---- header: title switcher + recording switch ----
        stack = Adw::ViewStack.new
        switcher = Adw::ViewSwitcher.new
        switcher.stack = stack
        switcher.policy = Adw::ViewSwitcherPolicy::Wide
        header = Adw::HeaderBar.new
        header.title_widget = switcher

        @recording = ::Gtk::Switch.new
        @recording.valign = ::Gtk::Align::Center
        @recording.tooltip_text = "Recording — switch off to pause"
        @recording.notify_signal["active"].connect { toggle_recording }
        rec_box = ::Gtk::Box.new(::Gtk::Orientation::Horizontal, 6)
        rec_label = ::Gtk::Label.new("Recording")
        rec_label.add_css_class("dim-label")
        rec_box.append(rec_label)
        rec_box.append(@recording)
        header.pack_end(rec_box)

        # ---- banner for "not running" / "paused" ----
        @banner = Adw::Banner.new("")
        @banner.button_clicked_signal.connect { banner_action }

        # ---- pages ----
        @status_label = ::Gtk::Label.new("")
        @activity_group = Adw::PreferencesGroup.new
        @activity_list = ::Gtk::ListBox.new
        @activity_empty = Adw::ActionRow.new
        @ignore_group = Adw::PreferencesGroup.new
        @daemon_row = Adw::ActionRow.new
        @daemon_button = ::Gtk::Button.new_with_label("Start")

        stack.add_titled_with_icon(activity_page, "activity", "Activity", "view-list-symbolic")
        stack.add_titled_with_icon(settings_page, "settings", "Settings", "emblem-system-symbolic")

        body = ::Gtk::Box.new(::Gtk::Orientation::Vertical, 0)
        body.append(@banner)
        body.append(stack)
        stack.vexpand = true

        view = Adw::ToolbarView.new
        view.add_top_bar(header)
        view.content = body
        @toasts.child = view
        @window.content = @toasts

        @link.on_change = ->(what : Symbol) { changed(what) }
        @link.on_event = ->(e : Events::Event) { fold(e) }
        refresh_state
        rebuild_activity
      end

      def present : Nil
        @window.present
      end

      # ---- Activity page --------------------------------------------------------

      private def activity_page : ::Gtk::Widget
        page = Adw::PreferencesPage.new

        top = Adw::PreferencesGroup.new
        @status_label.xalign = 0
        @status_label.wrap = true
        @status_label.add_css_class("dim-label")
        top.add(@status_label)
        page.add(top)

        range = ::Gtk::DropDown.new_from_strings(WINDOWS.map(&.[0]))
        range.selected = 1
        range.valign = ::Gtk::Align::Center
        range.notify_signal["selected"].connect do
          @window_secs = WINDOWS[range.selected][1]
          rebuild_activity
        end
        @activity_group.title = "What you've been doing"
        @activity_group.header_suffix = range
        @activity_list.add_css_class("boxed-list")
        @activity_list.selection_mode = ::Gtk::SelectionMode::None
        @activity_group.add(@activity_list)
        page.add(@activity_group)
        page
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
          @activity_empty.title = @link.connected? ? "No activity in this window" : "Start the daemon to see activity"
          @activity_empty.add_css_class("dim-label")
          @activity_list.append(@activity_empty) unless @activity_empty.parent
        elsif @activity_empty.parent
          @activity_list.remove(@activity_empty)
        end
      end

      private def row_for(e : History::Entry) : Adw::ActionRow
        row = Adw::ActionRow.new
        widget = e.name ? "#{e.role} “#{e.name}”" : (e.role || "?")
        row.title = "#{e.app}: #{widget}".gsub("&", "&amp;").gsub("<", "&lt;")
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
        String.build do |s|
          s << e.time.to_s("%H:%M:%S") << "  " << e.kind
          s << " ×" << e.count if e.count > 1
          if (u = e.until) && e.count > 1
            s << " over " << (u - e.time).total_seconds.round(1) << "s"
          end
          if t = e.text
            s << "  “" << t << "”"
          end
        end.gsub("&", "&amp;").gsub("<", "&lt;")
      end

      # ---- Settings page --------------------------------------------------------

      private def settings_page : ::Gtk::Widget
        page = Adw::PreferencesPage.new

        # Daemon
        daemon = Adw::PreferencesGroup.new
        daemon.title = "Daemon"
        @daemon_row.title = "Background service"
        @daemon_button.valign = ::Gtk::Align::Center
        @daemon_button.clicked_signal.connect { daemon_action }
        @daemon_row.add_suffix(@daemon_button)
        daemon.add(@daemon_row)
        page.add(daemon)

        # Recording
        rec = Adw::PreferencesGroup.new
        rec.title = "Recording"
        rec.description = "Kept in memory only, readable only by you. Nothing is written to disk unless the log is on."

        text = Adw::SwitchRow.new
        text.title = "Record typed text"
        text.subtitle = "Off: remember which field you edited and how much, not what you typed"
        text.active = @config.text
        text.notify_signal["active"].connect { save { @config.text = text.active? } }
        rec.add(text)

        retention = Adw::ComboRow.new
        retention.title = "Keep history for"
        labels = RETENTIONS.map(&.[0])
        current = RETENTIONS.index { |_, span| span == @config.retention }
        unless current
          labels << Config::Duration.format(@config.retention)
          current = labels.size - 1
        end
        retention.model = ::Gtk::StringList.new(labels)
        retention.selected = current.to_u32
        retention.notify_signal["selected"].connect do
          i = retention.selected.to_i
          save { @config.retention = RETENTIONS[i][1] } if i < RETENTIONS.size
        end
        rec.add(retention)

        log = Adw::SwitchRow.new
        log.title = "Durable log"
        log.subtitle = "Append every recorded event to #{Config.new.tap(&.log = true).log_dir}"
        log.active = @config.log != false
        log.notify_signal["active"].connect { save { @config.log = log.active? } }
        rec.add(log)

        a11y = Adw::SwitchRow.new
        a11y.title = "Turn on browser accessibility at start"
        a11y.subtitle = "Browsers only expose page content when this was on when they started"
        a11y.active = @config.accessibility
        a11y.notify_signal["active"].connect { save { @config.accessibility = a11y.active? } }
        rec.add(a11y)
        page.add(rec)

        # Ignore list
        @ignore_group.title = "Ignored applications"
        @ignore_group.description = "Never snapshotted, never recorded. Case-insensitive; * matches anything."
        add = Adw::EntryRow.new
        add.title = "Add an application name or pattern"
        add.show_apply_button = true
        add.apply_signal.connect do
          pattern = add.text.strip
          unless pattern.empty? || @config.ignore.includes?(pattern)
            save { @config.ignore << pattern }
            rebuild_ignore
          end
          add.text = ""
        end
        @ignore_group.add(add)
        pick = Adw::ActionRow.new # (ButtonRow needs libadwaita 1.6)
        pick.title = "Choose a running application…"
        pick.activatable = true
        pick.add_prefix(::Gtk::Image.new_from_icon_name("list-add-symbolic"))
        pick.activated_signal.connect { pick_application }
        @ignore_group.add(pick)
        rebuild_ignore
        page.add(@ignore_group)

        page
      end

      private def rebuild_ignore : Nil
        @ignore_rows.each { |r| @ignore_group.remove(r) }
        @ignore_rows.clear
        @config.ignore.each do |pattern|
          row = Adw::ActionRow.new
          row.title = pattern.gsub("&", "&amp;").gsub("<", "&lt;")
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
          row.title = name.gsub("&", "&amp;").gsub("<", "&lt;")
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
        if st
          @recording.sensitive = true
          @recording.active = !@link.paused?
          if p = st.paused_since
            @banner.title = "Recording paused since #{p.to_s("%H:%M")}"
            @banner.button_label = "Resume"
            @banner.revealed = true
          else
            @banner.revealed = false
          end
          @status_label.text = String.build do |s|
            s << "Daemon up since " << st.started.to_s("%H:%M") << " · "
            s << st.events << " events in the last " << Config::Duration.format(st.retention_seconds.seconds)
            s << " · typed text not recorded" unless st.text
            s << "\nLogging to " << st.log_dir if st.log_dir
          end
          @daemon_row.subtitle = "Running (pid #{st.pid})"
          @daemon_button.label = "Stop"
        else
          @recording.active = false
          @recording.sensitive = false
          @banner.title = "The daemon is not running — nothing is being recorded"
          @banner.button_label = "Start"
          @banner.revealed = true
          @status_label.text = ""
          @daemon_row.subtitle = @link.unit_installed? ? "Stopped (systemd user unit installed)" : "Stopped"
          @daemon_button.label = "Start"
        end
        @syncing = false
      end

      private def toggle_recording : Nil
        return if @syncing || !@link.connected?
        @recording.active? ? @link.resume : @link.pause
      end

      private def banner_action : Nil
        @link.connected? ? @link.resume : daemon_action
      end

      private def daemon_action : Nil
        error = @link.connected? ? @link.stop_daemon : @link.start_daemon
        toast(error) if error
      end

      # Persist a config change and tell the daemon.
      private def save(&) : Nil
        yield
        @config.save
        Config.current = @config
        if @link.connected?
          if error = @link.reload
            toast("Daemon rejected the config: #{error}")
          end
        end
      rescue ex : File::Error
        toast("Could not save #{Config.path}: #{ex.message}")
      end

      private def toast(message : String) : Nil
        @toasts.add_toast(Adw::Toast.new(title: message))
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
