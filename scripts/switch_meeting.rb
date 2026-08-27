#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"

options = { event_identity: "user" }
OptionParser.new do |parser|
  parser.banner = "Usage: switch_meeting.rb --session state.json --meeting-id ID --meeting-start ISO8601 [options]"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--meeting-id ID") { |value| options[:meeting_id] = value }
  parser.on("--meeting-start ISO8601") { |value| options[:meeting_start] = Time.parse(value).iso8601 }
  parser.on("--meeting-label LABEL") { |value| options[:meeting_label] = value }
  parser.on("--previous-meeting-end ISO8601") { |value| options[:previous_meeting_end] = Time.parse(value).iso8601 }
  parser.on("--event-identity IDENTITY") { |value| options[:event_identity] = value }
end.parse!

%i[session meeting_id meeting_start].each do |key|
  abort "Missing --#{key.to_s.tr('_', '-')}" if options[key].to_s.empty?
end
abort "--event-identity must be user or bot" unless %w[user bot].include?(options[:event_identity])

state = JSON.parse(File.read(options[:session]))
abort "Only active sessions can switch meetings" unless state["status"] == "active"

sessions = Array(state["meeting_sessions"])
current_id = state["current_meeting_id"].to_s
current_id = Array(state["meeting_ids"]).last.to_s if current_id.empty?
if current_id == options[:meeting_id]
  puts JSON.generate({ "ok" => true, "changed" => false, "meeting_id" => current_id })
  exit 0
end
abort "Meeting already exists in this course: #{options[:meeting_id]}" if sessions.any? { |item| item["meeting_id"].to_s == options[:meeting_id] }

if !current_id.empty?
  current = sessions.find { |item| item["meeting_id"].to_s == current_id }
  if current
    current["status"] = "ended"
    current["end_time"] = options[:previous_meeting_end] || state["last_transcript_end_time"] || options[:meeting_start]
  end
end

label = options[:meeting_label] || "第#{sessions.length + 1}场"
sessions << {
  "meeting_id" => options[:meeting_id],
  "label" => label,
  "start_time" => options[:meeting_start],
  "end_time" => nil,
  "status" => "active",
  "event_identity" => options[:event_identity]
}

state["version"] = [state["version"].to_i, 5].max
state["meeting_sessions"] = sessions
state["meeting_ids"] = (Array(state["meeting_ids"]) + [options[:meeting_id]]).uniq
state["current_meeting_id"] = options[:meeting_id]
state["course_start"] ||= sessions.first["start_time"]
state["meeting_start"] = options[:meeting_start]
state["event_identity"] = options[:event_identity]
state["meeting_status"] = "active"
state["last_transcript_end_time"] = options[:meeting_start]
state["last_transcript_end_ms"] = nil
state["last_transcript_scan_end_ms"] = nil
state["meeting_event_page_token"] = nil
state["updated_at"] = Time.now.iso8601

temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts JSON.pretty_generate({
  "ok" => true,
  "changed" => true,
  "meeting_id" => options[:meeting_id],
  "meeting_label" => label,
  "meeting_start" => options[:meeting_start],
  "course_start" => state["course_start"],
  "meeting_count" => sessions.length
})
