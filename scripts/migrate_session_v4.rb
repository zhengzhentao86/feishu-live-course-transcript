#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"
require_relative "session_index"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: migrate_session_v4.rb --session state.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
end.parse!
abort "Missing --session" if options[:session].to_s.empty?

state = JSON.parse(File.read(options[:session]))
if state["version"].to_i >= 4 && state["indexes"].is_a?(Hash)
  puts "migration_noop version=#{state['version']} cloud_reads=0"
  exit 0
end

index = SessionIndex.new(options[:session], state)
backup = index.migrate!
state["version"] = 4
state["ignored_transcript_records"] ||= []
state["last_transcript_end_time"] ||= state["meeting_start"]
state["meeting_event_page_token"] ||= nil
state["meeting_status"] ||= "active"
state["formal_minutes_available"] = false unless state.key?("formal_minutes_available")
state["updated_at"] = Time.now.iso8601

temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts "migration_complete version=4 backup=#{backup} index_counts=#{JSON.generate(index.compact_counts)} cloud_reads=0"
