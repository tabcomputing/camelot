module Camelot
  module Gtk
    # Runs blocks on GLib's turn of the loop.
    #
    # The pump lets other Crystal fibers run while it waits, and that wait
    # sits between GLib's prepare and check, where GDK holds a read claim on
    # the Wayland socket. A fiber that calls into GTK there — present() with
    # an activation token does a synchronous round trip — waits for a reader
    # that is waiting for it. So fibers never call GTK directly: they hand
    # the work here, and it runs from an idle source, inside dispatch, where
    # GTK expects to be called.
    module MainLoop
      @@queue = Deque(Proc(Nil)).new
      @@armed = false

      # A plain function (it captures nothing), so it can go to C as is.
      TRAMPOLINE = ->(_data : Pointer(Void)) { MainLoop.drain; 0 }

      def self.invoke(&block : -> Nil) : Nil
        @@queue << block
        return if @@armed
        @@armed = true
        LibGLib.g_idle_add_full(0, TRAMPOLINE.pointer, Pointer(Void).null, Pointer(Void).null)
      end

      # :nodoc:
      def self.drain : Nil
        @@armed = false
        while block = @@queue.shift?
          begin
            block.call
          rescue ex
            # Nothing may unwind through GLib's C frames.
            STDERR.puts "camelot-gtk: #{ex.inspect_with_backtrace}"
          end
        end
      end
    end
  end
end
