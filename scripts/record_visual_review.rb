#!/usr/bin/env ruby

require "digest"
require "json"
require "optparse"
require "time"

options = { yes: false }
OptionParser.new do |parser|
  parser.banner = "Usage: record_visual_review.rb --session state.json --confirm-all-legible --yes"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--confirm-all-legible") { options[:confirm_all_legible] = true }
  parser.on("--yes") { options[:yes] = true }
end.parse!
abort "Missing --session" if options[:session].to_s.empty?
abort "Visual review confirmation requires --confirm-all-legible --yes" unless options[:confirm_all_legible] && options[:yes]

preview_dir = File.join(File.dirname(options[:session]), "validation-previews")
manifest_path = File.join(preview_dir, "preview-manifest.json")
abort "Preview manifest missing; run prepare_validation_previews.rb first" unless File.file?(manifest_path)
manifest = JSON.parse(File.read(manifest_path))
items = Array(manifest["items"])
abort "Preview manifest has no items" if items.empty?
items.each do |item|
  output = item["output"].to_s
  abort "Preview missing: #{output}" unless File.file?(output)
  abort "Preview changed after inspection: #{output}" unless Digest::SHA256.file(output).hexdigest == item["sha256"]
end

review = manifest.merge(
  "reviewed_at" => Time.now.iso8601,
  "reviewer" => "Codex visual inspection",
  "all_legible" => true
)
review_path = File.join(preview_dir, "visual-review.json")
File.write(review_path, JSON.pretty_generate(review) + "\n")
puts JSON.pretty_generate({ "ok" => true, "review" => review_path, "items" => items.length })
