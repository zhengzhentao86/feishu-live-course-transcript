#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: commit_empty_poll.rb --session state.json --manifest manifest.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--manifest FILE") { |value| options[:manifest] = File.expand_path(value) }
end.parse!
%i[session manifest].each { |key| abort "Missing --#{key}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
manifest = JSON.parse(File.read(options[:manifest]))
abort "Empty-poll commit is not allowed after completion" if state["status"] == "completed"
abort "Manifest is not empty" unless Array(manifest["new_images"]).empty? && Array(manifest["new_transcripts"]).empty?
poll = manifest["poll"] || {}
state["unavailable_image_records"] ||= []
state["unavailable_image_records"] = (state["unavailable_image_records"] + Array(manifest["unavailable_images"])).uniq { |item| item["message_id"] }

if poll["last_message_position"]
  next_position = poll["last_message_position"].to_i
  abort "Message position cannot move backwards" if next_position < state["last_message_position"].to_i
  state["last_message_position"] = next_position
end

%w[last_message_time last_message_scan_end last_transcript_end_time].each do |field|
  next if poll[field].to_s.empty?
  next_time = Time.parse(poll[field])
  current_time = state[field].to_s.empty? ? nil : Time.parse(state[field])
  abort "#{field} cannot move backwards" if current_time && next_time < current_time
  state[field] = next_time.iso8601
end

if poll["last_transcript_end_ms"]
  state["last_transcript_end_ms"] = [state["last_transcript_end_ms"].to_i, poll["last_transcript_end_ms"].to_i].max
end
if poll.key?("meeting_event_page_token")
  token = poll["meeting_event_page_token"].to_s
  state["meeting_event_page_token"] = token.empty? ? nil : token
end

state["last_poll_completed_at"] = Time.now.iso8601
state["updated_at"] = Time.now.iso8601
temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts "empty_poll_committed cloud_writes=0 cloud_readbacks=0 model_calls=0"
