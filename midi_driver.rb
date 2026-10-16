#!/usr/bin/env ruby
# Ruby MIDI-to-keyboard driver for Linux/X11.
# MIDI input is read through ALSA's aseqdump; keyboard events use xdotool.
# GUI uses Ruby's Tk bindings.

require "json"
require "open3"
require "thread"
require "tk"

APP_DIR = File.expand_path(__dir__)
CONFIG_PATH = File.join(APP_DIR, "mappings.json")
DEFAULT_CONFIG = {
  "input_port" => "",
  "min_velocity" => 1,
  "velocity_mode" => "threshold",
  "mappings" => {
    "0:97"  => {"key" => "a", "min_velocity" => 1},
    "0:98"  => {"key" => "b", "min_velocity" => 1},
    "0:99"  => {"key" => "c", "min_velocity" => 1},
    "0:100" => {"key" => "d", "min_velocity" => 1},
    "0:101" => {"key" => "e", "min_velocity" => 1},
    "0:102" => {"key" => "f", "min_velocity" => 1},
    "0:103" => {"key" => "g", "min_velocity" => 1},
    "0:104" => {"key" => "h", "min_velocity" => 1},
    "0:105" => {"key" => "i", "min_velocity" => 1},
    "0:106" => {"key" => "j", "min_velocity" => 1},
    "0:107" => {"key" => "k", "min_velocity" => 1},
    "0:108" => {"key" => "l", "min_velocity" => 1},
    "0:109" => {"key" => "m", "min_velocity" => 1},
    "0:110" => {"key" => "n", "min_velocity" => 1},
    "0:111" => {"key" => "o", "min_velocity" => 1},
    "0:112" => {"key" => "p", "min_velocity" => 1},
    "0:113" => {"key" => "q", "min_velocity" => 1},
    "0:114" => {"key" => "r", "min_velocity" => 1},
    "0:115" => {"key" => "s", "min_velocity" => 1},
    "0:116" => {"key" => "t", "min_velocity" => 1},
    "0:117" => {"key" => "u", "min_velocity" => 1},
    "0:118" => {"key" => "v", "min_velocity" => 1},
    "0:119" => {"key" => "w", "min_velocity" => 1},
    "0:120" => {"key" => "x", "min_velocity" => 1},
    "0:121" => {"key" => "y", "min_velocity" => 1},
    "0:122" => {"key" => "z", "min_velocity" => 1}
  }
}.freeze

# Allowed xdotool key names include names such as "space", "Return",
# "Escape", "ctrl+c", "shift+Tab", "F1", "Left", etc.
# Do not enter shell syntax; commands are passed as argument arrays.
class MidiKeyboardDriver
  attr_reader :config, :running

  def initialize(on_status:, on_event:)
    @on_status = on_status
    @on_event = on_event
    @config_path = CONFIG_PATH
    @config = load_config(@config_path)
    @running = false
    @held = {} # [channel,note] => key
    @held_mutex = Mutex.new
    @worker = nil
    @reader = nil
    @learn_callback = nil
    @learn_mutex = Mutex.new
  end

  def load_config(path = @config_path)
    return Marshal.load(Marshal.dump(DEFAULT_CONFIG)) unless File.file?(path)

    data = JSON.parse(File.read(path))
    raise "Mapping file must contain a JSON object" unless data.is_a?(Hash)
    raise "Missing mappings object" unless data["mappings"].is_a?(Hash)

    data["input_port"] ||= ""
    data["min_velocity"] ||= 1
    data["velocity_mode"] ||= "threshold"
    data
  end

  def load_config_file(path)
    new_config = load_config(path)
    @config = new_config
    @config_path = File.expand_path(path)
  end

  def save_config(path = @config_path)
    path = File.expand_path(path)
    File.write("#{path}.tmp", JSON.pretty_generate(@config))
    File.rename("#{path}.tmp", path)
    @config_path = path
  end

  def config_path
    @config_path
  end

  def midi_ports
    stdout, _stderr, status = Open3.capture3("aconnect", "-l")
    raise "Cannot list MIDI ports. Install alsa-utils." unless status.success?

    ports = []
    client = nil
    stdout.each_line do |line|
      if line =~ /^\s*client\s+(\d+):\s*'([^']+)'/
        client = [$1, $2]
      elsif client && line =~ /^\s+(\d+)\s+'([^']+)'/
        port_id, port_name = $1, $2
        # Skip ALSA system/timer clients; list usable external/application ports.
        next if client[0].to_i <= 14
        ports << {
          "id" => "#{client[0]}:#{port_id}",
          "label" => "#{client[1]} — #{port_name} (#{client[0]}:#{port_id})"
        }
      end
    end
    ports
  rescue Errno::ENOENT
    raise "aconnect not found. Install it with: sudo pacman -S alsa-utils"
  end

  def start(port_id)
    stop
    raise "Choose a MIDI input port first." if port_id.to_s.strip.empty?
    raise "aconnect/aseqdump not found. Install alsa-utils." unless system("which", "aseqdump", out: File::NULL)

    @config["input_port"] = port_id
    @running = true
    @worker = Thread.new do
      begin
        @on_status.call("Connecting to MIDI port #{port_id}…")
        stdin, stdout, stderr, wait_thr = Open3.popen3("aseqdump", "-p", port_id)
        @reader = [stdin, stdout, stderr, wait_thr]
        stdin.close
        @on_status.call("Listening on #{port_id}")
        stdout.each_line do |line|
          break unless @running
          parse_alsa_line(line)
        end
        error_text = stderr.read rescue ""
        @on_status.call("MIDI input ended#{": #{error_text.strip}" unless error_text.to_s.strip.empty?}") if @running
      rescue => e
        @on_status.call("MIDI error: #{e.message}")
      ensure
        @running = false
        close_reader
      end
    end
  end

  def stop
    @running = false
    close_reader
    @worker&.kill if @worker&.alive?
    @worker = nil
    release_all
    @on_status.call("Stopped")
  end

  def close_reader
    reader = @reader
    @reader = nil
    return unless reader
    reader.each do |io|
      next unless io.respond_to?(:close) && !io.closed?
      io.close rescue nil
    end
  end

  def learn_next(&block)
    @learn_mutex.synchronize { @learn_callback = block }
    @on_status.call("Learning: press a note on your MIDI keyboard…")
  end

  def cancel_learn
    @learn_mutex.synchronize { @learn_callback = nil }
  end

  def mapping_key(channel, note)
    "#{channel}:#{note}"
  end

  def parse_alsa_line(line)
    # aseqdump examples:
    # Source Event Ch Data
    # 20:0 Note on 0, note 60, velocity 100
    # 20:0 Note off 0, note 60, velocity 0
    match = line.match(/\b(Note on|Note off)\s+(\d+),\s*note\s+(\d+),\s*velocity\s+(\d+)/i)
    return unless match
    kind = match[1].downcase
    channel = match[2].to_i
    note = match[3].to_i
    velocity = match[4].to_i
    if kind == "note on" && velocity.positive?
      handle_note_on(channel, note, velocity)
    else
      handle_note_off(channel, note)
    end
  end

  def handle_note_on(channel, note, velocity)
    learn_cb = @learn_mutex.synchronize do
      cb = @learn_callback
      @learn_callback = nil if cb
      cb
    end
    if learn_cb
      learn_cb.call(channel, note, velocity)
      return
    end

    id = mapping_key(channel, note)
    mapping = @config.fetch("mappings", {})[id]
    @on_event.call("ON  ch#{channel} note#{note} vel#{velocity}#{mapping ? " → #{mapping["key"]}" : " (unmapped)"}")
    return unless mapping

    threshold = (mapping["min_velocity"] || @config["min_velocity"] || 1).to_i
    return if velocity < threshold
    key = mapping["key"].to_s.strip
    return if key.empty?

    @held_mutex.synchronize do
      return if @held.key?(id)
      if keyboard("keydown", key)
        @held[id] = key
      end
    end
  end

  def handle_note_off(channel, note)
    id = mapping_key(channel, note)
    @on_event.call("OFF ch#{channel} note#{note}")
    @held_mutex.synchronize do
      key = @held.delete(id)
      keyboard("keyup", key) if key
    end
  end

  def keyboard(action, key)
    _out, err, status = Open3.capture3("xdotool", action, key)
    unless status.success?
      @on_status.call("xdotool failed: #{err.strip}")
      return false
    end
    true
  rescue Errno::ENOENT
    @on_status.call("xdotool not found. Install with pacman.")
    false
  end

  def release_all
    @held_mutex.synchronize do
      @held.each_value { |key| keyboard("keyup", key) }
      @held.clear
    end
  end
end

class MidiDriverGUI
  def initialize
    @root = TkRoot.new { title "MIDI Notes to Characters Driver"; minsize(760, 600) }
    @driver = MidiKeyboardDriver.new(
      on_status: ->(msg) { ui { @status_var.value = msg } },
      on_event: ->(msg) { ui { add_log(msg) } }
    )
    @selected_mapping = nil
    @port_ids = []
    build_ui
    refresh_ports
    load_mapping_table
    @root.protocol("WM_DELETE_WINDOW", proc { shutdown })
  end

  def ui(&block)
    @root.after(0, &block)
  rescue Tk::Error
    # Window is already closing.
  end

  def build_ui
    top = TkFrame.new(@root) { padx 10; pady 8 }.pack(fill: "x")
    TkLabel.new(top, text: "MIDI input:").pack(side: "left")
    @port_var = TkVariable.new
    @port_menu = Tk::Tile::Combobox.new(top) do
      textvariable @port_var
      state "readonly"
      width 48
    end
    @port_menu.pack(side: "left", padx: 6)
    TkButton.new(top, text: "Refresh", command: proc { refresh_ports }).pack(side: "left", padx: 3)
    @start_button = TkButton.new(top, text: "Start", command: proc { start_input })
    @start_button.pack(side: "left", padx: 3)
    TkButton.new(top, text: "Stop", command: proc { @driver.stop }).pack(side: "left", padx: 3)

    TkLabel.new(@root, textvariable: (@status_var = TkVariable.new("Ready")), anchor: "w",
      relief: "sunken", padx: 6, pady: 4).pack(fill: "x", padx: 10, pady: 4)

    mid = TkFrame.new(@root) { padx 10; pady 6 }.pack(fill: "both", expand: true)
    left = TkFrame.new(mid).pack(side: "left", fill: "both", expand: true)
    TkLabel.new(left, text: "Mappings (channel:note → key)", anchor: "w").pack(fill: "x")
    @mapping_list = TkListbox.new(left, height: 16, selectmode: "extended", exportselection: false)
    @mapping_list.pack(fill: "both", expand: true, pady: 4)
    @mapping_list.bind("<ButtonRelease-1>", proc { select_mapping })

    right = TkFrame.new(mid) { padx 10 }.pack(side: "left", fill: "y")
    TkLabel.new(right, text: "Selected mapping").pack(anchor: "w")
    TkLabel.new(right, text: "MIDI channel (0–15)").pack(anchor: "w", pady: [8, 0])
    @channel_var = TkVariable.new("0")
    TkSpinbox.new(right, from: 0, to: 15, textvariable: @channel_var, width: 8).pack(anchor: "w")
    TkLabel.new(right, text: "MIDI note (0–127)").pack(anchor: "w", pady: [8, 0])
    @note_var = TkVariable.new("60")
    TkSpinbox.new(right, from: 0, to: 127, textvariable: @note_var, width: 8).pack(anchor: "w")
    TkLabel.new(right, text: "xdotool key / shortcut").pack(anchor: "w", pady: [8, 0])
    @key_var = TkVariable.new("space")
    TkEntry.new(right, textvariable: @key_var, width: 22).pack(anchor: "w")
    TkLabel.new(right, text: "Minimum velocity (1–127)").pack(anchor: "w", pady: [8, 0])
    @velocity_var = TkVariable.new("1")
    TkSpinbox.new(right, from: 1, to: 127, textvariable: @velocity_var, width: 8).pack(anchor: "w")
    TkButton.new(right, text: "Learn note…", command: proc { learn_note }).pack(fill: "x", pady: [12, 3])
    TkButton.new(right, text: "Save / update mapping", command: proc { save_mapping }).pack(fill: "x", pady: 3)
    TkButton.new(right, text: "Delete mapping", command: proc { delete_mapping }).pack(fill: "x", pady: 3)
    TkLabel.new(right, text: "Velocity mode: threshold").pack(anchor: "w", pady: [10, 0])

    # TkButton.new(right, text: "Save JSON", command: proc { save_json }).pack(fill: "x", pady: 3)
    TkButton.new(
      right,
      text: "Load File...",
      command: proc { load_json_file }
    ).pack(fill: "x", pady: 3)

    TkButton.new(
      right,
      text: "Save As...",
      command: proc { save_json_as }
    ).pack(fill: "x", pady: 3)

    TkButton.new(
      right,
      text: "Save",
      command: proc { save_json }
    ).pack(fill: "x", pady: 3)

    bottom = TkFrame.new(@root) { padx 10; pady 6 }.pack(fill: "both", expand: true)
    TkLabel.new(bottom, text: "Event log", anchor: "w").pack(fill: "x")
    @log = TkText.new(bottom, height: 7, wrap: "none", state: "disabled")
    @log.pack(fill: "both", expand: true)
  end

  def refresh_ports
    ports = @driver.midi_ports
    @port_ids = ports.map { |p| p["id"] }
    labels = ports.map { |p| p["label"] }
    @port_menu.values = labels
    saved = @driver.config["input_port"]
    idx = @port_ids.index(saved)
    @port_var.value = labels[idx] || labels.first || ""
    @status_var.value = ports.empty? ? "No external MIDI ports found. Connect device and click Refresh." : "Found #{ports.length} MIDI input port(s)."
  rescue => e
    @status_var.value = e.message
  end

  def start_input
    idx = @port_menu.current
    port = @port_ids[idx] if idx && idx >= 0
    @driver.start(port || "")
  rescue => e
    @status_var.value = e.message
  end

  def load_mapping_table
    @mapping_list.delete(0, "end")
    @driver.config.fetch("mappings", {}).sort_by { |id, _| id.split(":").map(&:to_i) }.each do |id, m|
      @mapping_list.insert("end", "#{id}  →  #{m["key"]}  (min vel #{m["min_velocity"] || 1})")
    end
  end


  def select_mapping
    indices = @mapping_list.curselection.map(&:to_i)
    return if indices.empty?

    entries = @driver.config.fetch("mappings", {}).sort_by do |id, _|
      id.split(":").map(&:to_i)
    end

    entry = entries[indices.first]
    return unless entry

    @selected_mapping = entry[0]
    channel, note = @selected_mapping.split(":").map(&:to_i)
    mapping = entry[1]

    @channel_var.value = channel.to_s
    @note_var.value = note.to_s
    @key_var.value = mapping["key"].to_s
    @velocity_var.value = (mapping["min_velocity"] || 1).to_s

    @status_var.value =
        "#{indices.length} selected; editing first mapping"
  end

  def learn_note
    @driver.learn_next do |channel, note, _velocity|
      ui do
        @channel_var.value = channel.to_s
        @note_var.value = note.to_s
        @status_var.value = "Learned MIDI channel #{channel}, note #{note}. Enter a key and save."
      end
    end
  end

  def save_mapping
    channel = Integer(@channel_var.value)
    note = Integer(@note_var.value)
    velocity = Integer(@velocity_var.value)
    key = @key_var.value.to_s.strip
    raise "Channel must be 0–15." unless (0..15).cover?(channel)
    raise "Note must be 0–127." unless (0..127).cover?(note)
    raise "Minimum velocity must be 1–127." unless (1..127).cover?(velocity)
    raise "Enter an xdotool key name, e.g. space, Return, ctrl+c." if key.empty?
    id = "#{channel}:#{note}"
    @driver.config["mappings"][id] = { "key" => key, "min_velocity" => velocity }
    @selected_mapping = id
    load_mapping_table
    save_json
    @status_var.value = "Saved mapping #{id} → #{key}"
  rescue => e
    @status_var.value = "Mapping error: #{e.message}"
  end


  def delete_mapping
    indices = @mapping_list.curselection.map(&:to_i)

    entries = @driver.config.fetch("mappings", {}).sort_by do |id, _|
      id.split(":").map(&:to_i)
    end

    if indices.empty?
      channel = Integer(@channel_var.value)
      note = Integer(@note_var.value)
      ids = ["#{channel}:#{note}"]
    else
      ids = indices.filter_map { |index| entries[index]&.first }
    end

    ids.each { |id| @driver.config["mappings"].delete(id) }

    @selected_mapping = nil
    load_mapping_table
    @status_var.value = "Deleted #{ids.length} mapping(s)"
  rescue => e
    @status_var.value = "Delete error: #{e.message}"
  end

  def load_json_file
    path = Tk.getOpenFile(
      "title" => "Load MIDI mappings",
      "initialdir" => File.dirname(@driver.config_path),
      "filetypes" => [["JSON files", ".json"], ["All files", "*"]]
    )
    return if path.nil? || path.empty?

    @driver.load_config_file(path)
    @selected_mapping = nil
    load_mapping_table
    @status_var.value = "Loaded #{path}"
  rescue => e
    @status_var.value = "Load error: #{e.message}"
  end

  def save_json_as
    path = Tk.getSaveFile(
      "title" => "Save MIDI mappings as",
      "initialdir" => File.dirname(@driver.config_path),
      "initialfile" => File.basename(@driver.config_path),
      "defaultextension" => ".json",
      "filetypes" => [["JSON files", ".json"], ["All files", "*"]]
    )
    return if path.nil? || path.empty?

    path += ".json" if File.extname(path).empty?
    @driver.save_config(path)
    @status_var.value = "Saved #{path}"
  rescue => e
    @status_var.value = "Save error: #{e.message}"
  end

  def save_json
    @driver.save_config
    @status_var.value = "Saved #{@driver.config_path}"
  rescue => e
    @status_var.value = "Save error: #{e.message}"
  end

  def add_log(message)
    @log.configure("state" => "normal")
    @log.insert("end", "#{Time.now.strftime("%H:%M:%S")}  #{message}\n")
    @log.see("end")
    @log.configure("state" => "disabled")
  end

  def shutdown
    @driver.stop
    @root.destroy
  end

  def run
    Tk.mainloop
  end
end

unless system("which", "xdotool", out: File::NULL)
  warn "Missing xdotool. Install it with: sudo pacman -S xdotool"
end
unless system("which", "aseqdump", out: File::NULL)
  warn "Missing aseqdump. Install it with: sudo pacman -S alsa-utils"
end

MidiDriverGUI.new.run
