#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rexml/document"
require "time"
require_relative "transcript_fidelity"
require_relative "session_index"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = { dry_run: false }
OptionParser.new do |parser|
  parser.banner = "Usage: validate_session.rb --session state.json [--dry-run]"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--dry-run") { options[:dry_run] = true }
end.parse!
abort "Missing --session" if options[:session].to_s.empty?

state = JSON.parse(File.read(options[:session]))
session_dir = File.dirname(options[:session])
session_index = SessionIndex.new(options[:session], state)
accepted = Array(state["accepted_slides"])
transcript_blocks = Array(state["transcript_blocks"])
content_groups = Array(state["content_groups"])
canonical_records = content_groups.empty? ? (accepted + transcript_blocks) : content_groups
assigned_transcript_ids = canonical_records.flat_map { |item| Array(item["transcript_ids"]) }.reject { |value| value.to_s.empty? }
processed_transcript_ids = session_index.values("processed_transcript_ids").to_a
ignored_transcript_ids = session_index.values("ignored_transcript_ids").to_a
transcript_end_values = canonical_records.map { |item| item["course_end_time_ms"] || item["transcript_end_ms"] }.map(&:to_i).select(&:positive?)
course_times = canonical_records.map { |item| item["course_time_ms"] || item["transcript_start_ms"] }.compact.map(&:to_i)
group_ids = content_groups.map { |item| item["group_id"] }.reject { |value| value.to_s.empty? }
physical_index_checks = SessionIndex::FIELDS.each_with_object({}) do |field, memo|
  relative = state.dig("indexes", field) || File.join("indexes", "#{field}.txt")
  file_path = File.expand_path(relative, session_dir)
  physical_values = File.file?(file_path) ? File.readlines(file_path, chomp: true).reject(&:empty?).uniq : []
  memo[field] = physical_values.sort == session_index.values(field).to_a.sort
end

local_checks = {
  "unique_message_ids" => accepted.map { |item| item["message_id"] }.compact.uniq.length == accepted.length,
  "unique_image_keys" => accepted.map { |item| item["image_key"] }.reject { |value| value.to_s.empty? }.then { |values| values.uniq.length == values.length },
  "ordered_positions" => accepted.map { |item| item["position"].to_i } == accepted.map { |item| item["position"].to_i }.sort,
  "unique_segment_ids" => transcript_blocks.map { |item| item["segment_id"] }.uniq.length == transcript_blocks.length,
  "unique_content_group_ids" => content_groups.empty? || group_ids.uniq.length == group_ids.length,
  "course_timeline_monotonic" => course_times == course_times.sort,
  "transcript_ids_assigned_once" => assigned_transcript_ids.uniq.length == assigned_transcript_ids.length,
  "ignored_transcript_ids_unique" => ignored_transcript_ids.uniq.length == ignored_transcript_ids.length,
  "ignored_transcript_ids_not_written" => (ignored_transcript_ids & assigned_transcript_ids).empty?,
  "processed_transcript_ids_unique" => processed_transcript_ids.uniq.length == processed_transcript_ids.length,
  "processed_transcript_ids_match_assignments" => processed_transcript_ids.sort == (assigned_transcript_ids + ignored_transcript_ids).uniq.sort,
  "transcript_cursor_covers_written_blocks" => transcript_end_values.empty? ||
    (content_groups.empty? ? state["last_transcript_end_ms"].to_i : state["last_course_time_ms"].to_i) >= transcript_end_values.max,
  "paragraph_lengths_valid" => canonical_records.all? do |item|
    values = item["paragraphs"].is_a?(Array) ? item["paragraphs"] : [item["text"]]
    values.all? { |text| text.to_s.length.positive? && text.to_s.length <= TranscriptFidelity::MAX_PARAGRAPH_LENGTH }
  end,
  "source_text_recorded" => state["version"].to_i < 2 || canonical_records.all? { |item| !item["source_text"].to_s.strip.empty? },
  "physical_indexes_match_canonical_state" => physical_index_checks.values.all?,
  "no_pending_document_rebuild" => state["requires_document_rebuild"] != true
}

if options[:dry_run]
  result = {
    "mode" => "dry_run",
    "accepted_slides" => accepted.length,
    "transcript_blocks" => transcript_blocks.length,
    "checks" => local_checks,
    "passed" => local_checks.values.all?
  }
  puts JSON.pretty_generate(result)
  exit(result["passed"] ? 0 : 1)
end

abort "Full validation is allowed only after status becomes finalizing" unless state["status"] == "finalizing"
abort "Finalization has no start timestamp" if state["finalization_started_at"].to_s.empty?
abort "Final incremental batch has not completed" if state["final_incremental_completed_at"].to_s.empty?
abort "Minutes correction has not completed" if state["minutes_corrected_at"].to_s.empty?
abort "Minutes source ID is missing" if state["minutes_source_id"].to_s.empty?
abort "Minutes correction batch ID is missing" if state["minutes_correction_batch_id"].to_s.empty?
abort "Minutes-corrected revision is missing" if state["minutes_corrected_revision"].to_s.empty?
abort "Full validation already completed at #{state['full_validation_completed_at']}" unless state["full_validation_completed_at"].to_s.empty?

final_document = state["final_document"].is_a?(Hash) ? state["final_document"] : nil
doc_token = (final_document || state["document"] || {})["token"].to_s
abort "Session has no document token" if doc_token.empty?
section_title = state.dig("document", "section_title").to_s

def parse_envelope(stdout)
  JSON.parse(stdout)
rescue JSON::ParserError
  stdout.enum_for(:scan, /\{/).map { Regexp.last_match.begin(0) }.reverse_each do |index|
    begin
      payload = JSON.parse(stdout[index..])
      return payload if payload.is_a?(Hash) && payload.key?("ok")
    rescue JSON::ParserError
      next
    end
  end
  raise
end

def run_cli(*args, chdir:)
  stdout, stderr, status = Open3.capture3(CLI_ENV, CLI_BIN, *args, chdir: chdir)
  payload = parse_envelope(stdout)
  unless status.success? && payload["ok"] == true
    error = payload["error"] || {}
    abort "lark-cli failed: #{error['code']} #{error['message']}\n#{stderr.lines.last(5).join}"
  end
  payload
end

document = run_cli(
  "docs", "+fetch", "--doc", doc_token,
  "--doc-format", "xml", "--detail", "full", "--scope", "full",
  "--as", "user", "--format", "json",
  chdir: session_dir
).dig("data", "document") || abort("Fetch response has no document")
expected_revision = final_document ? final_document["revision"] : state["minutes_corrected_revision"]
abort "Document revision changed after final binding: expected=#{expected_revision} current=#{document['revision_id']}" unless document["revision_id"].to_s == expected_revision.to_s

xml = REXML::Document.new("<root>#{document.fetch('content')}</root>")
heading = REXML::XPath.match(xml, "//h1").find do |node|
  node.children.map(&:to_s).join.gsub(/<[^>]+>/, "").strip == section_title
end
abort "Could not find section heading: #{section_title}" unless final_document || heading

# A newly created course document has one course section, so full-document images
# are the authoritative count. Appending to an existing document requires a
# dedicated section fetch in the live workflow before using this validator.
images = REXML::XPath.match(xml, "//img")
names = images.map { |node| node.attributes["name"].to_s }
resource_images = images.select { |node| %w[token src url href].any? { |key| !node.attributes[key].to_s.empty? } }
transcript_stamps = canonical_records.map do |block|
  start_time = block["course_time"] || block["meeting_time"]
  end_time = block["course_end_time"] || block["meeting_end_time"]
  range = end_time.to_s.empty? || end_time == start_time ? start_time : "#{start_time}–#{end_time}"
  "#{block['speaker']} · #{range}"
end
chapter_count = REXML::XPath.match(xml, "//h1").count do |node|
  text = node.children.map(&:to_s).join.gsub(/<[^>]+>/, "").strip
  text != "阅读说明" && text != "课程信息" && text != section_title
end
captioned_images = images.count { |node| node.attributes["caption"].to_s.match?(/正式 PPT 第 \d{3} 页｜课程约 /) }
cloud_checks = {
  "image_count_matches_state" => images.length == accepted.length,
  "image_names_unique" => names.uniq.length == names.length,
  "all_images_have_resources" => resource_images.length == images.length,
  "all_state_images_present_once" => accepted.all? { |slide| names.count(slide["image_name"]) == 1 },
  "all_image_timestamps_present" => accepted.all? { |slide| document.fetch("content").include?("#{state['teacher']} · #{slide['course_time'] || slide['meeting_time']}") },
  "all_text_timestamps_present" => transcript_stamps.all? { |stamp| document.fetch("content").include?(stamp) },
  "all_text_block_ids_present" => final_document || transcript_blocks.all? { |block| !block["stamp_block_id"].to_s.empty? && !block["body_block_id"].to_s.empty? },
  "semantic_chapters_present" => !final_document || chapter_count >= (canonical_records.length >= 10 ? 2 : 1),
  "final_image_captions_stable" => !final_document || captioned_images == images.length
}

preview_dir = File.join(session_dir, "validation-previews")
visual_review_path = File.join(preview_dir, "visual-review.json")
visual_review = File.file?(visual_review_path) ? JSON.parse(File.read(visual_review_path)) : {}
preview_results = Array(visual_review["items"])
visual_revision_matches = visual_review["revision"].to_s == document["revision_id"].to_s
visual_count_matches = visual_review["image_count"].to_i == images.length
visual_files_match = preview_results.all? do |item|
  output = item["output"].to_s
  File.file?(output) && Digest::SHA256.file(output).hexdigest == item["sha256"]
end

checks = local_checks.merge(cloud_checks).merge(
  "preview_first_middle_last" => visual_review["all_legible"] == true && preview_results.length == [images.length, 3].min &&
    visual_revision_matches && visual_count_matches && visual_files_match
)
result = {
  "mode" => "live",
  "document_token" => doc_token,
  "revision" => document["revision_id"],
  "accepted_slides" => accepted.length,
  "transcript_blocks" => transcript_blocks.length,
  "cloud_images" => images.length,
  "checks" => checks,
  "previews" => preview_results,
  "passed" => checks.values.all?,
  "validated_at" => Time.now.iso8601
}

File.write(File.join(session_dir, "validation.json"), JSON.pretty_generate(result) + "\n")
if result["passed"]
  state["full_validation_completed_at"] = result["validated_at"]
  if final_document
    state["final_document"]["revision"] = document["revision_id"] if document["revision_id"]
  else
    state["document"]["revision"] = document["revision_id"] if document["revision_id"]
  end
  state_tmp = "#{options[:session]}.tmp"
  File.write(state_tmp, JSON.pretty_generate(state) + "\n")
  File.rename(state_tmp, options[:session])
end
puts JSON.pretty_generate(result)
exit(result["passed"] ? 0 : 1)
