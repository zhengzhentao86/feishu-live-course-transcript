#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rexml/document"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: prepare_validation_previews.rb --session state.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
end.parse!
abort "Missing --session" if options[:session].to_s.empty?

state = JSON.parse(File.read(options[:session]))
session_dir = File.dirname(options[:session])
document_state = state["final_document"].is_a?(Hash) ? state["final_document"] : state["document"]
doc_token = document_state["token"].to_s
abort "Session has no document token" if doc_token.empty?

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

document = run_cli(
  "docs", "+fetch", "--doc", doc_token, "--doc-format", "xml", "--detail", "full", "--scope", "full",
  "--as", "user", "--format", "json", chdir: session_dir
).dig("data", "document") || abort("Fetch response has no document")
xml = REXML::Document.new("<root>#{document.fetch('content')}</root>")
images = REXML::XPath.match(xml, "//img")
abort "Document has no images to preview" if images.empty?

preview_dir = File.join(session_dir, "validation-previews")
FileUtils.mkdir_p(preview_dir)
indices = [0, images.length / 2, images.length - 1].uniq
items = indices.map do |index|
  token = %w[token src url href].map { |key| images[index].attributes[key].to_s }.find { |value| !value.empty? }
  abort "Image #{index + 1} has no resource token" if token.to_s.empty?
  relative_output = File.join("validation-previews", "#{index + 1}.jpg")
  output = File.join(session_dir, relative_output)
  run_cli(
    "docs", "+media-preview", "--token", token, "--output", relative_output, "--overwrite",
    "--as", "user", "--format", "json", chdir: session_dir
  )
  abort "Preview file missing: #{output}" unless File.file?(output) && File.size(output).positive?
  { "index" => index, "position" => index + 1, "output" => output, "sha256" => Digest::SHA256.file(output).hexdigest }
end

manifest = {
  "document_token" => doc_token,
  "revision" => document["revision_id"],
  "image_count" => images.length,
  "items" => items
}
manifest_path = File.join(preview_dir, "preview-manifest.json")
File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
puts JSON.pretty_generate({ "ok" => true, "manifest" => manifest_path, "items" => items })
