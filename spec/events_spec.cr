require "./spec_helper"

# The pump needs no accessibility bus: any GLib source on the default
# context will do to prove GLib work and Crystal fibers interleave.
module PumpProbe
  class_property glib_fired = 0
end

describe Camelot::Events::Pump do
  it "dispatches GLib sources while Crystal fibers keep running" do
    PumpProbe.glib_fired = 0
    tick = ->(_data : Pointer(Void)) { PumpProbe.glib_fired += 1; 1 }
    id = LibGLib.g_timeout_add_full(0, 20_u32, tick.pointer, Pointer(Void).null, Pointer(Void).null)

    crystal_ticks = 0
    stop = Channel(Nil).new
    spawn do
      5.times { sleep 30.milliseconds; crystal_ticks += 1 }
      stop.send(nil)
    end

    started = Time.instant
    Camelot::Events::Pump.new.run(stop: stop)
    LibGLib.g_source_remove(id)

    (Time.instant - started).should be < 1.second
    crystal_ticks.should eq 5
    PumpProbe.glib_fired.should be >= 4 # ~150ms of 20ms ticks
  end

  # The pump used to `next` straight back to the top whenever GLib said a
  # source was ready, with no yield point: one always-ready source starved
  # every other fiber and burned a core (the daemon stopped answering).
  it "keeps other fibers running while a GLib source is always ready" do
    PumpProbe.glib_fired = 0
    always = ->(_data : Pointer(Void)) { PumpProbe.glib_fired += 1; 1 }
    id = LibGLib.g_idle_add_full(0, always.pointer, Pointer(Void).null, Pointer(Void).null)

    crystal_ticks = 0
    stop = Channel(Nil).new
    spawn do
      5.times { sleep 20.milliseconds; crystal_ticks += 1 }
      stop.send(nil)
    end

    started = Time.instant
    Camelot::Events::Pump.new.run(stop: stop)
    LibGLib.g_source_remove(id)

    crystal_ticks.should eq 5                      # the fiber was never starved
    (Time.instant - started).should be < 2.seconds # and it was not slowed to a crawl
    PumpProbe.glib_fired.should be > 0             # GLib kept getting its turns too
  end

  # The pump used to `next` straight back to the top whenever GLib said a
  # source was ready, with no yield point: one always-ready source starved
  # every other fiber and burned a core (the daemon stopped answering).
  it "keeps other fibers running while a GLib source is always ready" do
    PumpProbe.glib_fired = 0
    always = ->(_data : Pointer(Void)) { PumpProbe.glib_fired += 1; 1 }
    id = LibGLib.g_idle_add_full(0, always.pointer, Pointer(Void).null, Pointer(Void).null)

    crystal_ticks = 0
    stop = Channel(Nil).new
    spawn do
      5.times { sleep 20.milliseconds; crystal_ticks += 1 }
      stop.send(nil)
    end

    started = Time.instant
    Camelot::Events::Pump.new.run(stop: stop)
    LibGLib.g_source_remove(id)

    crystal_ticks.should eq 5                      # the fiber was never starved
    (Time.instant - started).should be < 2.seconds # and it was not slowed to a crawl
    PumpProbe.glib_fired.should be > 0             # GLib kept getting its turns too
  end

  it "honours a deadline" do
    started = Time.instant
    Camelot::Events::Pump.new.run(deadline: Time.instant + 50.milliseconds)
    (Time.instant - started).should be >= 50.milliseconds
    (Time.instant - started).should be < 500.milliseconds
  end
end
