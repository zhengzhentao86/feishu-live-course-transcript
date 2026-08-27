#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "optparse"
require "time"
require_relative "session_index"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: migrate_session_v5.rb --session state.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
end.parse!
abort "Missing --session" if options[:session].to_s.empty?

state = JSON.parse(File.read(options[:session]))
if state["version"].to_i >= 5 && Array(state["content_groups"]).any?
  puts JSON.generate({ "ok" => true, "changed" => false, "version" => state["version"] })
  exit 0
end

backup_path = options[:session] + ".v4-backup.json"
File.write(backup_path, JSON.pretty_generate(state) + "\n") unless File.exist?(backup_path)

course_start = state["course_start"]
completed = Array(state["completed_meeting_sessions"])
meeting_sessions = Array(state["meeting_sessions"])
if meeting_sessions.empty?
  meeting_sessions = completed.map.with_index do |item, index|
    {
      "meeting_id" => item["meeting_id"],
      "label" => item["topic"].to_s.empty? ? "第#{index + 1}场" : item["topic"],
      "start_time" => item["start_time"],
      "end_time" => item["end_time"],
      "status" => "ended",
      "event_identity" => state["event_identity"] || "user"
    }
  end
end
if meeting_sessions.empty? && Array(state["meeting_ids"]).any?
  meeting_sessions = Array(state["meeting_ids"]).map.with_index do |meeting_id, index|
    {
      "meeting_id" => meeting_id,
      "label" => "第#{index + 1}场",
      "start_time" => index.zero? ? state["meeting_start"] : nil,
      "end_time" => nil,
      "status" => meeting_id == Array(state["meeting_ids"]).last ? state["meeting_status"] : "ended",
      "event_identity" => state["event_identity"] || "user"
    }
  end
end
course_start ||= meeting_sessions.first&.dig("start_time") || state["meeting_start"]

records = []
Array(state["transcript_blocks"]).each do |block|
  records << block.merge("kind" => "text", "image_message_ids" => [], "image_names" => [])
end
Array(state["accepted_slides"]).each do |slide|
  records << slide.merge(
    "kind" => "image_group",
    "image_message_ids" => [slide["message_id"]].compact,
    "image_names" => [slide["image_name"]].compact
  )
end

grouped = {}
records.each_with_index do |record, index|
  transcript_ids = Array(record["transcript_ids"]).map(&:to_s).reject(&:empty?)
  key_material = transcript_ids.empty? ? [record["meeting_id"], record["meeting_time"], record["source_text"]] : transcript_ids
  key = Digest::SHA256.hexdigest(key_material.join("\u0000"))[0, 20]
  group = grouped[key] ||= {
    "group_id" => record["segment_id"] || "migrated:#{key}",
    "kind" => record["kind"],
    "meeting_id" => record["meeting_id"],
    "meeting_label" => record["meeting_label"],
    "meeting_time" => record["meeting_time"],
    "meeting_end_time" => record["meeting_end_time"],
    "course_time" => record["course_time"] || record["meeting_time"],
    "course_end_time" => record["course_end_time"] || record["meeting_end_time"],
    "course_time_ms" => record["course_time_ms"] || record["timeline_ms"] || record["transcript_start_ms"],
    "course_end_time_ms" => record["course_end_time_ms"] || record["transcript_end_ms"],
    "speaker" => record["speaker"] || state["teacher"],
    "chapter_title" => record["chapter_title"],
    "paragraphs" => Array(record["paragraphs"] || record["text"]),
    "source_text" => record["source_text"],
    "transcript_ids" => transcript_ids,
    "image_message_ids" => [],
    "image_names" => [],
    "legacy_order" => index
  }
  group["kind"] = "image_group" if record["kind"] == "image_group"
  group["image_message_ids"] |= Array(record["image_message_ids"])
  group["image_names"] |= Array(record["image_names"])
end

groups = grouped.values.sort_by do |group|
  [group["course_time_ms"].nil? ? 1 : 0, group["course_time_ms"].to_i, group["legacy_order"]]
end
groups.each { |group| group.delete("legacy_order") }

legacy_times = records.map { |record| record["course_time_ms"] || record["timeline_ms"] || record["transcript_start_ms"] }.compact.map(&:to_i)
timeline_reset = legacy_times.each_cons(2).any? { |left, right| right < left }
duplicate_transcripts = records.flat_map { |record| Array(record["transcript_ids"]) }.then { |ids| ids.length != ids.uniq.length }

state["version"] = 5
state["course_start"] = course_start
state["meeting_sessions"] = meeting_sessions
state["current_meeting_id"] ||= Array(state["meeting_ids"]).last
state["event_identity"] ||= meeting_sessions.last&.dig("event_identity") || "user"
state["speaker_mode"] ||= "single_teacher"
state["content_groups"] = groups
state["current_chapter"] ||= nil
state["chapter_history"] ||= []
state["unavailable_image_records"] ||= []
state["last_course_time_ms"] = groups.map { |group| group["course_end_time_ms"].to_i }.max
state["requires_document_rebuild"] = state["requires_document_rebuild"] == true || timeline_reset || duplicate_transcripts
state["updated_at"] = Time.now.iso8601

index = SessionIndex.new(options[:session], state)
index.configure_state!
SessionIndex::FIELDS.each do |field|
  values = index.values(field).to_a.sort
  index_path = File.expand_path(state.dig("indexes", field), File.dirname(options[:session]))
  FileUtils.mkdir_p(File.dirname(index_path))
  File.write(index_path, values.join("\n") + (values.empty? ? "" : "\n"))
  state[field] = []
  state["index_counts"][field] = values.length
end

temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts JSON.pretty_generate({
  "ok" => true,
  "changed" => true,
  "version" => 5,
  "content_groups" => groups.length,
  "meeting_sessions" => meeting_sessions.length,
  "requires_document_rebuild" => state["requires_document_rebuild"],
  "backup" => backup_path,
  "index_counts" => state["index_counts"]
})
