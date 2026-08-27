#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "optparse"
require "rexml/document"
require "rexml/formatters/default"
require "time"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = { parent_position: "my_library", max_images: 8, max_blocks: 60 }
OptionParser.new do |parser|
  parser.banner = "Usage: publish_final_document.rb --session state.json --xml final.xml --title TITLE [options]"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--xml FILE") { |value| options[:xml] = File.expand_path(value) }
  parser.on("--title TITLE") { |value| options[:title] = value }
  parser.on("--parent-position POSITION") { |value| options[:parent_position] = value }
  parser.on("--max-images N", Integer) { |value| options[:max_images] = value }
  parser.on("--max-blocks N", Integer) { |value| options[:max_blocks] = value }
  parser.on("--dry-run") { options[:dry_run] = true }
end.parse!
%i[session xml title].each { |key| abort "Missing --#{key}" if options[key].to_s.empty? }
abort "--max-images must be between 1 and 20" unless (1..20).cover?(options[:max_images])
abort "--max-blocks must be between 10 and 100" unless (10..100).cover?(options[:max_blocks])

state = JSON.parse(File.read(options[:session]))
abort "Final publish only runs during finalizing" unless state["status"] == "finalizing"
abort "Final document already bound" if state["final_document"].is_a?(Hash) && !state.dig("final_document", "token").to_s.empty?
session_dir = File.dirname(options[:session])
abort "Final XML must be inside the session directory" unless options[:xml].start_with?(session_dir + File::SEPARATOR)

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

def run_cli(*args, chdir:)
  stdout, stderr, cmd_status = Open3.capture3(CLI_ENV, CLI_BIN, *args, chdir: chdir)
  payload = parse_envelope(stdout)
  unless cmd_status.success? && payload["ok"] == true
    error = payload["error"] || {}
    abort "lark-cli failed: #{error['code']} #{error['message']}\n#{stderr.lines.last(5).join}"
  end
  payload
end

def find_value(object, keys)
  return nil unless object.is_a?(Hash) || object.is_a?(Array)
  if object.is_a?(Hash)
    keys.each { |key| return object[key] if object.key?(key) && !object[key].to_s.empty? }
    object.each_value do |value|
      result = find_value(value, keys)
      return result unless result.nil?
    end
  else
    object.each do |value|
      result = find_value(value, keys)
      return result unless result.nil?
    end
  end
  nil
end

def serialize(node)
  output = +""
  REXML::Formatters::Default.new.write(node, output)
  output
end

def plain_text(node)
  node.children.map { |child| child.is_a?(REXML::Element) ? plain_text(child) : child.to_s }.join.gsub(/\s+/, " ").strip
end

document = REXML::Document.new("<root>#{File.read(options[:xml])}</root>")
nodes = document.root.elements.to_a
abort "Final XML has no top-level blocks" if nodes.empty?

units = []
current_unit = []
nodes.each do |node|
  starts_group = node.name == "h1" || (node.name == "p" && plain_text(node).match?(/· \d{2}:\d{2}:\d{2}/))
  if starts_group && !current_unit.empty?
    units << current_unit
    current_unit = []
  end
  current_unit << node
end
units << current_unit unless current_unit.empty?

chunks = []
current_chunk = []
current_images = 0
current_blocks = 0
units.each do |unit|
  unit_images = unit.sum do |node|
    (node.name == "img" ? 1 : 0) + REXML::XPath.match(node, "descendant::img").length
  end
  unit_blocks = unit.length
  if !current_chunk.empty? && (current_images + unit_images > options[:max_images] || current_blocks + unit_blocks > options[:max_blocks])
    chunks << current_chunk
    current_chunk = []
    current_images = 0
    current_blocks = 0
  end
  current_chunk.concat(unit)
  current_images += unit_images
  current_blocks += unit_blocks
end
chunks << current_chunk unless current_chunk.empty?

chunk_dir = File.join(session_dir, "final-publish-chunks")
FileUtils.mkdir_p(chunk_dir)
chunk_paths = chunks.each_with_index.map do |chunk, index|
  file_path = File.join(chunk_dir, format("%03d.xml", index + 1))
  File.write(file_path, chunk.map { |node| serialize(node) }.join("\n") + "\n")
  file_path
end

if options[:dry_run]
  puts JSON.pretty_generate({
    "ok" => true,
    "dry_run" => true,
    "chunks" => chunk_paths.length,
    "chunk_paths" => chunk_paths,
    "images" => REXML::XPath.match(document, "//img").length
  })
  exit 0
end

first_relative = File.basename(chunk_dir) + "/" + File.basename(chunk_paths.first)
create_payload = run_cli(
  "docs", "+create", "--title", options[:title], "--content", "@./#{first_relative}",
  "--doc-format", "xml", "--parent-position", options[:parent_position],
  "--as", "user", "--format", "json", chdir: session_dir
)
doc_token = find_value(create_payload, %w[document_token doc_token obj_token token]).to_s
doc_url = find_value(create_payload, %w[url document_url])
abort "Document created but response did not contain a document token" if doc_token.empty?

fetch_payload = run_cli(
  "docs", "+fetch", "--doc", doc_token, "--doc-format", "xml", "--detail", "full", "--scope", "full",
  "--as", "user", "--format", "json", chdir: session_dir
)
fetched = fetch_payload.dig("data", "document") || abort("Fetch response has no document")
revision = fetched["revision_id"]
fetched_xml = REXML::Document.new("<root>#{fetched.fetch('content')}</root>")
first_expected = REXML::Document.new("<root>#{File.read(chunk_paths.first)}</root>")
REXML::XPath.match(first_expected, "//img").each do |expected_image|
  name = expected_image.attributes["name"].to_s
  matches = REXML::XPath.match(fetched_xml, "//img").select { |node| node.attributes["name"].to_s == name }
  abort "Initial final image verification failed for #{name}" unless matches.length == 1
  abort "Initial final image resource missing for #{name}" unless %w[token src url href].any? { |key| !matches.first.attributes[key].to_s.empty? }
end
tail = fetched_xml.root.elements.to_a.last&.attributes&.[]("id").to_s
abort "Could not resolve final document tail after create" if tail.empty?

chunk_paths.drop(1).each do |chunk_path|
  relative = File.basename(chunk_dir) + "/" + File.basename(chunk_path)
  expected = REXML::Document.new("<root>#{File.read(chunk_path)}</root>")
  expected_names = REXML::XPath.match(expected, "//img").map { |node| node.attributes["name"].to_s }
  update = run_cli(
    "docs", "+update", "--doc", doc_token, "--command", "append", "--content", "@./#{relative}",
    "--revision-id", revision.to_s, "--as", "user", "--format", "json", chdir: session_dir
  ).fetch("data")
  abort "Unexpected final append result" unless update["result"] == "success" && Array(update["warnings"]).empty?
  revision = update.dig("document", "revision_id") || abort("Final append response has no revision")
  sleep 1
  verified = run_cli(
    "docs", "+fetch", "--doc", doc_token, "--doc-format", "xml", "--detail", "full", "--scope", "range",
    "--start-block-id", tail, "--end-block-id", "-1", "--revision-id", revision.to_s,
    "--as", "user", "--format", "json", chdir: session_dir
  ).dig("data", "document") || abort("Range fetch response has no document")
  abort "Revision drift during final publish" unless verified["revision_id"].to_s == revision.to_s
  verified_xml = REXML::Document.new("<root>#{verified.fetch('content')}</root>")
  expected_names.each do |name|
    matches = REXML::XPath.match(verified_xml, "//img").select { |node| node.attributes["name"].to_s == name }
    abort "Final image verification failed for #{name}" unless matches.length == 1
    abort "Final image resource missing for #{name}" unless %w[token src url href].any? { |key| !matches.first.attributes[key].to_s.empty? }
  end
  tail = verified_xml.root.elements.to_a.last&.attributes&.[]("id").to_s
  abort "Could not resolve final document tail after chunk append" if tail.empty?
end

result = {
  "ok" => true,
  "document_token" => doc_token,
  "document_url" => doc_url,
  "revision" => revision,
  "chunks" => chunk_paths.length,
  "images" => REXML::XPath.match(document, "//img").length,
  "published_at" => Time.now.iso8601
}
state["final_document"] = {
  "token" => doc_token,
  "url" => doc_url,
  "revision" => revision,
  "bound_at" => result["published_at"]
}
state["updated_at"] = result["published_at"]
state_temp_path = options[:session] + ".tmp"
File.write(state_temp_path, JSON.pretty_generate(state) + "\n")
File.rename(state_temp_path, options[:session])
result_path = File.join(session_dir, "final-publish-result.json")
File.write(result_path, JSON.pretty_generate(result) + "\n")
puts JSON.pretty_generate(result.merge("result" => result_path))
