#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "fileutils"
require "pathname"

ROOT = Pathname.new(__dir__).join("..").expand_path
LABEL = "com.codex.feishu-live-course-transcript.github-sync"
INTERVAL_SECONDS = 300
uid = Process.uid
home_dir = Dir.home
launch_agents_dir = File.join(home_dir, "Library", "LaunchAgents")
logs_dir = File.join(home_dir, "Library", "Logs", "Codex")
plist_path = File.join(launch_agents_dir, "#{LABEL}.plist")
log_path = File.join(logs_dir, "feishu-live-course-transcript-github-sync.log")

FileUtils.mkdir_p(launch_agents_dir)
FileUtils.mkdir_p(logs_dir)

escape = ->(value) { CGI.escapeHTML(value.to_s) }
plist = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>Label</key>
    <string>#{escape.call(LABEL)}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/bin/ruby</string>
      <string>#{escape.call(ROOT.join("scripts/github_auto_sync.rb"))}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>#{escape.call(ROOT)}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>#{INTERVAL_SECONDS}</integer>
    <key>StandardOutPath</key>
    <string>#{escape.call(log_path)}</string>
    <key>StandardErrorPath</key>
    <string>#{escape.call(log_path)}</string>
  </dict>
  </plist>
XML
File.write(plist_path, plist, mode: "w", perm: 0o600)

domain = "gui/#{uid}"
system("/bin/launchctl", "bootout", domain, plist_path, out: File::NULL, err: File::NULL)
abort("无法加载自动同步任务") unless system("/bin/launchctl", "bootstrap", domain, plist_path)
system("/bin/launchctl", "enable", "#{domain}/#{LABEL}")

puts "label=#{LABEL}"
puts "interval_seconds=#{INTERVAL_SECONDS}"
puts "plist=#{plist_path}"
puts "log=#{log_path}"
