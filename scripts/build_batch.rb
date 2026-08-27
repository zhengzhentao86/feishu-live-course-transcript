#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"
require_relative "transcript_fidelity"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: build_batch.rb --session state.json --manifest manifest.json --model-output decisions.json --output batch.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--manifest FILE") { |value| options[:manifest] = File.expand_path(value) }
  parser.on("--model-output FILE") { |value| options[:model_output] = File.expand_path(value) }
  parser.on("--output FILE") { |value| options[:output] = File.expand_path(value) }
end.parse!
%i[session manifest model_output output].each { |key| abort "Missing --#{key.to_s.tr('_', '-')}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
manifest = JSON.parse(File.read(options[:manifest]))
decisions = JSON.parse(File.read(options[:model_output]))
transcripts = Array(manifest["new_transcripts"]).each_with_object({}) { |item, memo| memo[item.fetch("transcript_id")] = item }
images = Array(manifest["new_images"]).each_with_object({}) { |item, memo| memo[item.fetch("message_id")] = item }
assigned = []
meeting_meta = manifest["meeting"] || {}
meeting_start_value = meeting_meta["start_time"] || state["meeting_start"]
course_start_value = meeting_meta["course_start"] || state["course_start"] || meeting_start_value
abort "Missing meeting start" if meeting_start_value.to_s.empty?
abort "Missing course start" if course_start_value.to_s.empty?

def relative_stamp(absolute_time, meeting_start)
  seconds = [(Time.parse(absolute_time) - Time.parse(meeting_start)).round, 0].max
  format("%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
end

entries = Array(decisions["assignments"]).map do |decision|
  ids = Array(decision["transcript_ids"]).map(&:to_s)
  abort "Assignment has no transcript_ids" if ids.empty?
  abort "Unknown transcript ID" unless ids.all? { |id| transcripts.key?(id) }
  overlap = assigned & ids
  abort "Transcript assigned more than once: #{overlap.join(',')}" unless overlap.empty?
  assigned.concat(ids)
  selected = ids.map { |id| transcripts[id] }
  source_text = selected.map { |item| item["text"].to_s }.join
  start_time = selected.map { |item| Time.parse(item["start_time"]) }.min
  end_time = selected.map { |item| Time.parse(item["end_time"]) }.max
  speaker = decision["speaker"].to_s
  speaker = state["speaker_map"][speaker] if state["speaker_map"].is_a?(Hash) && state["speaker_map"].key?(speaker)
  speaker = state["teacher"] if state["speaker_mode"] == "single_teacher"
  speaker = state["teacher"] if speaker.to_s.empty?
  base = {
    "kind" => decision.fetch("kind"),
    "transcript_ids" => ids,
    "transcript_start_ms" => ((start_time - Time.parse(meeting_start_value)) * 1000).round,
    "transcript_end_ms" => ((end_time - Time.parse(meeting_start_value)) * 1000).round,
    "course_time_ms" => ((start_time - Time.parse(course_start_value)) * 1000).round,
    "course_end_time_ms" => ((end_time - Time.parse(course_start_value)) * 1000).round,
    "meeting_time" => relative_stamp(start_time.iso8601, meeting_start_value),
    "meeting_end_time" => relative_stamp(end_time.iso8601, meeting_start_value),
    "course_time" => relative_stamp(start_time.iso8601, course_start_value),
    "course_end_time" => relative_stamp(end_time.iso8601, course_start_value),
    "meeting_id" => meeting_meta["meeting_id"] || state["current_meeting_id"] || Array(state["meeting_ids"]).last,
    "meeting_label" => meeting_meta["label"] || "当前场次",
    "speaker" => speaker,
    "source_text" => source_text,
    "paragraphs" => Array(decision["paragraphs"]),
    "chapter_title" => decision["chapter_title"].to_s.strip
  }
  if %w[image image_group].include?(base["kind"])
    message_ids = Array(decision["message_ids"]).map(&:to_s).reject(&:empty?)
    message_ids = [decision["message_id"].to_s] if message_ids.empty?
    abort "Image assignment has no message_id or message_ids" if message_ids.all?(&:empty?)
    selected_images = message_ids.map do |message_id|
      image = images[message_id] || abort("Unknown image message_id: #{message_id}")
      {
        "message_id" => image["message_id"],
        "image_key" => image["image_key"],
        "position" => image["message_position"],
        "sent_at" => image["create_time"],
        "local_path" => image["local_path"],
        "slide_title" => image["ocr_title"] || "标题待识别",
        "ocr_text" => image["ocr_text"],
        "normalized_ocr" => image["normalized_ocr"]
      }
    end
    selected_images.each_with_index do |image, index|
      title = Array(decision["slide_titles"])[index]
      image["slide_title"] = title unless title.to_s.strip.empty?
    end
    if selected_images.length == 1
      image = selected_images.first
      image["slide_title"] = decision["slide_title"] unless decision["slide_title"].to_s.strip.empty?
      base["kind"] = "image"
      base["layout"] = "single"
      base.merge!(image)
    else
      abort "Multi-image assignment must use alignment_mode=shared_explanation" unless decision["alignment_mode"] == "shared_explanation"
      alignment_reason = decision["alignment_reason"].to_s.strip
      abort "Multi-image assignment requires a concrete alignment_reason" if alignment_reason.empty?
      base["kind"] = "image_group"
      base["layout"] = "grid"
      base["alignment_mode"] = "shared_explanation"
      base["alignment_reason"] = alignment_reason
      base["images"] = selected_images.sort_by { |image| [image["position"].to_i, image["sent_at"].to_s] }
      base["group_id"] = "#{base['meeting_id']}:#{base['course_time_ms']}:#{message_ids.first}"
    end
  elsif base["kind"] == "text"
    meeting_id = base["meeting_id"] || "meeting"
    base["segment_id"] = "#{meeting_id}:#{base['transcript_start_ms']}:#{base['transcript_end_ms']}:#{speaker}"
  else
    abort "Unsupported kind: #{base['kind']}"
  end
  report = TranscriptFidelity.report(base, require_source: true)
  abort "Transcript fidelity failed at #{report['label']}: #{report['failures'].join('; ')}" unless report["failures"].empty?
  base
end

ignored = Array(decisions["ignored_transcripts"])
ignored_ids = ignored.flat_map { |item| Array(item["transcript_ids"]) }.map(&:to_s)
all_ids = transcripts.keys.sort
covered_ids = (assigned + ignored_ids).uniq.sort
abort "Transcript coverage incomplete" unless covered_ids == all_ids

used_image_ids = entries.flat_map do |entry|
  if entry["kind"] == "image"
    [entry["message_id"]]
  elsif entry["kind"] == "image_group"
    Array(entry["images"]).map { |image| image["message_id"] }
  else
    []
  end
end
missing_images = images.keys - used_image_ids
abort "New images missing from batch: #{missing_images.join(',')}" unless missing_images.empty?

batch = {
  "poll" => manifest["poll"] || {},
  "unavailable_images" => manifest["unavailable_images"] || [],
  "ignored_transcripts" => ignored,
  "entries" => entries.sort_by { |entry| [entry["course_time_ms"] || entry["transcript_start_ms"], entry["kind"] == "text" ? 1 : 0] }
}
File.write(options[:output], JSON.pretty_generate(batch) + "\n")
puts JSON.generate({ "ok" => true, "output" => options[:output], "entries" => entries.length, "images" => used_image_ids.length, "transcript_coverage" => all_ids.length })
