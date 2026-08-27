#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"
require_relative "session_index"

options = { max_window_seconds: 600 }
OptionParser.new do |parser|
  parser.banner = "Usage: filter_incremental_inputs.rb --session state.json --messages messages.json --events events.json [--scan-end ISO8601] [--output manifest.json]"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--messages FILE") { |value| options[:messages] = File.expand_path(value) }
  parser.on("--events FILE") { |value| options[:events] = File.expand_path(value) }
  parser.on("--scan-end ISO8601") { |value| options[:scan_end] = value }
  parser.on("--output FILE") { |value| options[:output] = File.expand_path(value) }
  parser.on("--max-window-seconds N", Integer) { |value| options[:max_window_seconds] = value }
end.parse!

%i[session messages events].each do |key|
  abort "Missing --#{key}" if options[key].to_s.empty?
end
abort "--max-window-seconds must be between 120 and 600" unless (120..600).cover?(options[:max_window_seconds])

state = JSON.parse(File.read(options[:session]))
messages_payload = JSON.parse(File.read(options[:messages]))
events_payload = JSON.parse(File.read(options[:events]))
messages_data = messages_payload["data"] || messages_payload
events_data = events_payload["data"] || events_payload
pagination_complete = messages_payload.dig("meta", "pagination", "complete")
abort "Message pagination incomplete; do not advance cursors" if pagination_complete == false

def parse_time(value, meeting_start: nil)
  raw = value.to_s.strip
  return nil if raw.empty?
  if raw.match?(/\A\d+(?:\.\d+)?\z/)
    number = raw.to_f
    return Time.at(number / 1000.0) if number >= 1_000_000_000_000
    return Time.at(number) if number >= 1_000_000_000
    return Time.parse(meeting_start) + (number / 1000.0) unless meeting_start.to_s.empty?
  end
  Time.parse(raw)
rescue ArgumentError
  nil
end

current_meeting_id = state["current_meeting_id"].to_s
current_meeting_id = Array(state["meeting_ids"]).last.to_s if current_meeting_id.empty?
meeting_session = Array(state["meeting_sessions"]).find { |item| item["meeting_id"].to_s == current_meeting_id }
meeting_start = meeting_session&.dig("start_time") || state["meeting_start"]
course_start = state["course_start"] || Array(state["meeting_sessions"]).first&.dig("start_time") || meeting_start
last_position = state["last_message_position"].to_i
last_message_scan_end = parse_time(state["last_message_scan_end"] || state["last_message_time"], meeting_start: meeting_start)
scan_end = parse_time(options[:scan_end], meeting_start: meeting_start)
last_transcript_time = parse_time(state["last_transcript_end_time"], meeting_start: meeting_start)
index = SessionIndex.new(options[:session], state)
processed_messages = index.values("processed_message_ids")
processed_images = index.values("processed_image_keys")
processed_transcripts = index.values("processed_transcript_ids")

transcripts = Array(events_data["events"]).flat_map do |event|
  next [] unless event["event_type"] == "transcript_received"
  Array(event.dig("payload", "transcript_received_items")).map do |item|
    sentence_id = item["sentence_id"].to_s
    start_time = parse_time(item["start_time_ms"], meeting_start: meeting_start)
    end_time = parse_time(item["end_time_ms"], meeting_start: meeting_start)
    next if sentence_id.empty? || item["text"].to_s.strip.empty? || start_time.nil? || end_time.nil?
    next if processed_transcripts.include?(sentence_id)
    next if last_transcript_time && end_time <= last_transcript_time
    {
      "transcript_id" => sentence_id,
      "event_id" => event["event_id"],
      "start_time" => start_time.iso8601(3),
      "end_time" => end_time.iso8601(3),
      "start_time_ms" => item["start_time_ms"],
      "end_time_ms" => item["end_time_ms"],
      "speaker" => item["speaker"],
      "text" => item["text"].to_s.strip
    }
  end.compact
end
# Later cumulative events may carry a more complete text for the same sentence.
# Keep the last occurrence while still emitting the final list in time order.
transcripts = transcripts.reverse.uniq { |item| item["transcript_id"] }.reverse.sort_by { |item| Time.parse(item["start_time"]) }

window_start = transcripts.empty? ? nil : Time.parse(transcripts.first["start_time"])
window_cutoff = window_start && (window_start + options[:max_window_seconds])
selected_transcripts = window_cutoff ? transcripts.take_while { |item| Time.parse(item["end_time"]) <= window_cutoff } : []
selected_transcripts = [transcripts.first] if selected_transcripts.empty? && !transcripts.empty?

message_candidates = Array(messages_data["messages"]).map do |message|
  position = message["message_position"].to_i
  created_at = parse_time(message["create_time"], meeting_start: meeting_start)
  next if position <= last_position || created_at.nil?
  next if last_message_scan_end && created_at < last_message_scan_end
  { "raw" => message, "position" => position, "created_at" => created_at }
end.compact.sort_by { |item| [item["position"], item["created_at"]] }

message_window_start = message_candidates.first&.dig("created_at")
effective_cutoff = window_cutoff || (message_window_start && message_window_start + options[:max_window_seconds])

photographer = state["photographer"].to_s.strip
photographer_id = state["photographer_id"].to_s.strip
messages = message_candidates.take_while { |item| effective_cutoff.nil? || item["created_at"] <= effective_cutoff }

unavailable_images = []
new_images = messages.map do |wrapped|
  message = wrapped["raw"]
  next unless message["msg_type"] == "image"
  if message["deleted"] == true
    unavailable_images << {
      "message_id" => message["message_id"],
      "message_position" => wrapped["position"],
      "create_time" => wrapped["created_at"].iso8601,
      "reason" => "deleted_image"
    }
    next
  end
  next if processed_messages.include?(message["message_id"].to_s)
  sender = message["sender"] || {}
  sender_match = (!photographer_id.empty? && sender["id"].to_s == photographer_id) ||
    (!photographer.empty? && sender["name"].to_s == photographer)
  sender_match = true if photographer_id.empty? && photographer.empty?
  next unless sender_match
  image_key = message["content"].to_s[/!\[Image\]\(([^)]+)\)/, 1] || message["content"].to_s[/img_[A-Za-z0-9_-]+/]
  next if image_key.to_s.empty? || processed_images.include?(image_key)
  {
    "message_id" => message["message_id"],
    "image_key" => image_key,
    "message_position" => wrapped["position"],
    "create_time" => wrapped["created_at"].iso8601,
    "sender_id" => sender["id"],
    "sender_name" => sender["name"]
  }
end.compact

last_scanned_message = messages.last
selected_transcript_end = selected_transcripts.empty? ? last_transcript_time : Time.parse(selected_transcripts.last["end_time"])
meeting_start_time = parse_time(meeting_start, meeting_start: nil)
selected_transcript_end_ms = if selected_transcript_end && meeting_start_time
  ((selected_transcript_end - meeting_start_time) * 1000).round
else
  state["last_transcript_end_ms"]
end
all_transcripts_selected = selected_transcripts.length == transcripts.length
event_page_token = all_transcripts_selected ? events_data["page_token"] : nil

manifest = {
  "meeting" => {
    "meeting_id" => current_meeting_id,
    "label" => meeting_session&.dig("label") || "当前场次",
    "start_time" => meeting_start,
    "course_start" => course_start,
    "event_identity" => meeting_session&.dig("event_identity") || state["event_identity"] || "user"
  },
  "window" => {
    "target_seconds" => state["batch_target_seconds"] || 300,
    "max_seconds" => options[:max_window_seconds],
    "start_time" => (window_start || message_window_start)&.iso8601,
    "cutoff_time" => effective_cutoff&.iso8601,
    "backlog_remaining" => transcripts.length - selected_transcripts.length,
    "message_backlog_remaining" => message_candidates.length - messages.length
  },
  "new_images" => new_images,
  "unavailable_images" => unavailable_images,
  "new_transcripts" => selected_transcripts,
  "download_message_ids" => new_images.map { |item| item["message_id"] },
  "poll" => {
    "last_message_position" => last_scanned_message ? last_scanned_message["position"] : last_position,
    "last_message_time" => last_scanned_message ? last_scanned_message["created_at"].iso8601 : state["last_message_time"],
    "last_message_scan_end" => scan_end&.iso8601 || state["last_message_scan_end"],
    "last_transcript_end_time" => selected_transcript_end&.iso8601(3),
    "last_transcript_end_ms" => selected_transcript_end_ms,
    "meeting_event_page_token" => event_page_token
  },
  "route" => {
    "new_image_count" => new_images.length,
    "new_transcript_chars" => selected_transcripts.sum { |item| item["text"].to_s.length },
    "transcript_duration_seconds" => selected_transcripts.empty? ? 0 : (Time.parse(selected_transcripts.last["end_time"]) - Time.parse(selected_transcripts.first["start_time"])).round,
    "ambiguous_alignment_count" => 0,
    "comments_count" => 0,
    "meeting_status" => state["meeting_status"] || state["status"] || "active",
    "formal_minutes_available" => state["formal_minutes_available"] == true,
    "revision_drift" => false,
    "structure_error" => false,
    "previous_validation_failed" => false,
    "retry_count" => 0,
    "speaker_count" => selected_transcripts.map { |item| item.dig("speaker", "name") || item["speaker"].to_s }.reject(&:empty?).uniq.length,
    "meeting_switch_count" => 0,
    "historical_backfill_required" => state["requires_document_rebuild"] == true,
    "speaker_mapping_missing" => state["speaker_mode"] == "multi_speaker" && state["speaker_map"].to_h.empty?
  },
  "stats" => {
    "messages_in_window" => messages.length,
    "new_images" => new_images.length,
    "unavailable_images" => unavailable_images.length,
    "new_transcripts" => selected_transcripts.length,
    "historical_images_read" => 0,
    "historical_images_ocr" => 0
  }
}

output = JSON.pretty_generate(manifest) + "\n"
if options[:output]
  File.write(options[:output], output)
  puts JSON.generate({ "ok" => true, "output" => options[:output], "new_images" => new_images.length, "new_transcripts" => selected_transcripts.length, "backlog_remaining" => manifest.dig("window", "backlog_remaining") })
else
  puts output
end
