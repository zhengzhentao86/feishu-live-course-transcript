#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "time"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = { now: Time.now.iso8601 }
OptionParser.new do |parser|
  parser.banner = "Usage: collect_incremental.rb --session state.json --output-dir DIR [--now ISO8601]"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--output-dir DIR") { |value| options[:output_dir] = File.expand_path(value) }
  parser.on("--now ISO8601") { |value| options[:now] = Time.parse(value).iso8601 }
end.parse!
%i[session output_dir].each { |key| abort "Missing --#{key.to_s.tr('_', '-')}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
FileUtils.mkdir_p(options[:output_dir])
manifest_path = File.join(options[:output_dir], "manifest.json")

if state["status"] == "completed"
  manifest = {
    "new_images" => [], "new_transcripts" => [], "unavailable_images" => [], "download_message_ids" => [],
    "poll" => {},
    "route" => {
      "new_image_count" => 0, "new_transcript_chars" => 0, "transcript_duration_seconds" => 0,
      "ambiguous_alignment_count" => 0, "comments_count" => 0, "meeting_status" => "completed",
      "formal_minutes_available" => false, "revision_drift" => false, "structure_error" => false,
      "previous_validation_failed" => false, "retry_count" => 0, "speaker_count" => 0,
      "meeting_switch_count" => 0
    },
    "stats" => { "lark_calls" => 0, "historical_images_read" => 0, "historical_images_ocr" => 0 }
  }
  File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
  puts JSON.generate({ "ok" => true, "completed" => true, "manifest" => manifest_path, "lark_calls" => 0 })
  exit 0
end

chat_id = state["chat_id"].to_s
meeting_id = state["current_meeting_id"].to_s
meeting_id = Array(state["meeting_ids"]).last.to_s if meeting_id.empty?
meeting_session = Array(state["meeting_sessions"]).find { |item| item["meeting_id"].to_s == meeting_id }
event_identity = meeting_session&.dig("event_identity") || state["event_identity"] || "user"
abort "Session has no chat_id" if chat_id.empty?
abort "Session has no current meeting_id" if meeting_id.empty?
message_start = state["last_message_scan_end"] || state["last_message_time"] || state["meeting_start"]
transcript_start = state["last_transcript_end_time"] || state["meeting_start"]
abort "Session has no message start cursor" if message_start.to_s.empty?
abort "Session has no transcript start cursor" if transcript_start.to_s.empty? && state["meeting_event_page_token"].to_s.empty?

def parse_envelope(stdout)
  JSON.parse(stdout)
rescue JSON::ParserError
  stdout.enum_for(:scan, /\{/).map { Regexp.last_match.begin(0) }.reverse_each do |index|
    begin
      value = JSON.parse(stdout[index..])
      return value if value.is_a?(Hash) && value.key?("ok")
    rescue JSON::ParserError
      next
    end
  end
  raise
end

def run_cli(args, chdir)
  stdout, stderr, cmd_status = Open3.capture3(CLI_ENV, CLI_BIN, *args, chdir: chdir)
  safe_error = stderr.lines.last(5).join
    .gsub(%r{https?://\S+}, "[url]")
    .gsub(/[A-Za-z0-9_-]{24,}/, "[redacted]")
    .strip
  if stdout.to_s.strip.empty?
    abort "lark-cli returned empty stdout (exit #{cmd_status.exitstatus}): #{safe_error}"
  end
  begin
    payload = parse_envelope(stdout)
  rescue JSON::ParserError
    abort "lark-cli returned non-JSON stdout (exit #{cmd_status.exitstatus}): #{safe_error}"
  end
  unless cmd_status.success? && payload["ok"] == true
    error = payload["error"] || {}
    abort "lark-cli failed: #{error['code']} #{error['message']}\n#{stderr.lines.last(3).join}"
  end
  payload
end

message_args = [
  "im", "+chat-messages-list", "--chat-id", chat_id,
  "--start", Time.parse(message_start.to_s).iso8601, "--end", options[:now],
  "--order", "asc", "--page-all", "--no-reactions", "--as", "user", "--format", "json"
]
event_args = ["vc", "+meeting-events", "--meeting-id", meeting_id]
if state["meeting_event_page_token"].to_s.empty?
  event_args += ["--start", Time.parse(transcript_start.to_s).iso8601, "--end", options[:now]]
else
  event_args += ["--page-token", state["meeting_event_page_token"]]
end
event_args += ["--page-all", "--as", event_identity, "--format", "json"]

threads = [message_args, event_args].map { |args| Thread.new { run_cli(args, options[:output_dir]) } }
messages_payload, events_payload = threads.map(&:value)
messages_path = File.join(options[:output_dir], "messages.raw.json")
events_path = File.join(options[:output_dir], "events.raw.json")
File.write(messages_path, JSON.pretty_generate(messages_payload) + "\n")
File.write(events_path, JSON.pretty_generate(events_payload) + "\n")

filter_script = File.join(__dir__, "filter_incremental_inputs.rb")
stdout, stderr, cmd_status = Open3.capture3(
  RbConfig.ruby, filter_script,
  "--session", options[:session], "--messages", messages_path, "--events", events_path,
  "--scan-end", options[:now], "--output", manifest_path
)
abort "Incremental filter failed: #{stderr}" unless cmd_status.success?
manifest = JSON.parse(File.read(manifest_path))
message_ids = Array(manifest["download_message_ids"])
abort "More than 50 new images in one hot batch; split by cursor before download" if message_ids.length > 50

lark_calls = 2
unless message_ids.empty?
  downloads = run_cli([
    "im", "+messages-mget", "--message-ids", message_ids.join(","),
    "--no-reactions", "--download-resources", "--as", "user", "--format", "json"
  ], options[:output_dir])
  lark_calls += 1
  download_path = File.join(options[:output_dir], "images.download.json")
  File.write(download_path, JSON.pretty_generate(downloads) + "\n")
  resources = Array(downloads.dig("data", "messages") || downloads["messages"]).flat_map { |message| Array(message["resources"]) }
  Array(manifest["new_images"]).each do |image|
    resource = resources.find { |item| item["key"].to_s == image["image_key"].to_s }
    local_path = resource && File.expand_path(resource["local_path"].to_s, options[:output_dir])
    abort "Downloaded image resource missing: #{image['message_id']}" unless local_path && File.file?(local_path)
    image["local_path"] = local_path
  end

  ocr_input = File.join(options[:output_dir], "ocr-input.json")
  ocr_output = File.join(options[:output_dir], "ocr-output.json")
  File.write(ocr_input, JSON.pretty_generate({ "items" => manifest["new_images"] }) + "\n")
  image_dirs = Array(manifest["new_images"]).map { |item| File.dirname(item["local_path"]) }.uniq
  ocr_script = File.join(__dir__, "ocr_images.swift")
  ocr_stdout, ocr_stderr, ocr_status = Open3.capture3("swift", ocr_script, ocr_input, *image_dirs, ocr_output)
  abort "OCR failed: #{ocr_stderr}" unless ocr_status.success?
  ocr_items = JSON.parse(File.read(ocr_output)).fetch("items")
  Array(manifest["new_images"]).each do |image|
    result = ocr_items.find { |item| item["message_id"] == image["message_id"] }
    next unless result
    image["ocr_text"] = result["ocr_text"]
    image["ocr_title"] = result["ocr_text"].to_s.lines.map(&:strip).find { |line| !line.empty? } || "标题待识别"
    image["normalized_ocr"] = result["ocr_text"].to_s.downcase.scan(/[\p{Han}a-z0-9]/u).join
  end
end

manifest["stats"] ||= {}
manifest["stats"]["lark_calls"] = lark_calls
manifest["stats"]["historical_images_read"] = 0
manifest["stats"]["historical_images_ocr"] = 0
File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
puts JSON.generate({ "ok" => true, "manifest" => manifest_path, "new_images" => manifest["new_images"].length, "new_transcripts" => manifest["new_transcripts"].length, "lark_calls" => lark_calls })
