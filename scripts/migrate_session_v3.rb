#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"
require "rexml/document"
require "time"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: migrate_session_v3.rb --session state.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
end.parse!
abort "Missing --session" if options[:session].to_s.empty?

state = JSON.parse(File.read(options[:session]))
session_dir = File.dirname(options[:session])
document_state = state["document"] || abort("Session has no document state")

if state["version"].to_i >= 3 && !document_state["append_anchor_block_id"].to_s.empty?
  puts "migration_noop version=#{state['version']} cloud_reads=0"
  exit 0
end

doc_token = document_state["token"].to_s
recorded_revision = document_state["revision"]
section_title = document_state["section_title"].to_s
abort "Session has no document token" if doc_token.empty?
abort "Session has no recorded revision" if recorded_revision.nil?
abort "Session has no section title" if section_title.empty?

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

def plain_text(node)
  node.children.map { |child| child.is_a?(REXML::Element) ? plain_text(child) : child.to_s }.join.gsub(/\s+/, " ").strip
end

outline = run_cli(
  "docs", "+fetch", "--doc", doc_token,
  "--doc-format", "xml", "--detail", "with-ids", "--scope", "outline",
  "--as", "user", "--format", "json",
  chdir: session_dir
).dig("data", "document") || abort("Outline fetch response has no document")
abort "Revision drift during migration: state=#{recorded_revision} cloud=#{outline['revision_id']}" unless outline["revision_id"].to_s == recorded_revision.to_s

outline_xml = REXML::Document.new("<root>#{outline.fetch('content')}</root>")
heading = REXML::XPath.match(outline_xml, "//h1").find { |node| plain_text(node) == section_title }
abort "Could not resolve section heading: #{section_title}" unless heading
heading_id = heading.attributes["id"].to_s

section = run_cli(
  "docs", "+fetch", "--doc", doc_token,
  "--doc-format", "xml", "--detail", "with-ids", "--scope", "section",
  "--start-block-id", heading_id, "--revision-id", recorded_revision.to_s,
  "--as", "user", "--format", "json",
  chdir: session_dir
).dig("data", "document") || abort("Section fetch response has no document")
abort "Revision drift during migration section fetch" unless section["revision_id"].to_s == recorded_revision.to_s

section_xml = REXML::Document.new("<root>#{section.fetch('content')}</root>")
last_node = section_xml.root.elements.to_a.reverse.find { |node| !node.attributes["id"].to_s.empty? }
tail_id = last_node&.attributes&.[]("id").to_s
tail_id = heading_id if tail_id.empty?

state["version"] = 3
state["poll_interval_seconds"] = 300
state["last_message_scan_end"] ||= state["last_message_time"] || state["meeting_start"]
state["last_transcript_scan_end_ms"] ||= state["last_transcript_end_ms"]
state["last_transcript_end_time"] ||= state["meeting_start"]
state["meeting_event_page_token"] ||= nil
state["batch_target_seconds"] ||= 300
state["batch_max_seconds"] ||= 600
state["last_poll_completed_at"] ||= nil
state["last_batch_completed_at"] ||= nil
state["ignored_transcript_ids"] ||= []
state["finalization_started_at"] ||= nil
state["final_incremental_completed_at"] ||= nil
state["minutes_corrected_at"] ||= nil
state["minutes_source_id"] ||= nil
state["minutes_correction_batch_id"] ||= nil
state["minutes_corrected_revision"] ||= nil
state["full_validation_completed_at"] ||= nil
state["finalized_at"] ||= nil
document_state["section_block_id"] = heading_id
document_state["append_anchor_block_id"] = tail_id
state["updated_at"] = Time.now.iso8601

temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts "migration_complete version=3 cloud_reads=2 section_block_id=#{heading_id} append_anchor_block_id=#{tail_id}"
