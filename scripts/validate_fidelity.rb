#!/usr/bin/env ruby

require "json"
require "optparse"
require_relative "transcript_fidelity"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: validate_fidelity.rb --batch batch.json"
  parser.on("--batch FILE") { |value| options[:batch] = File.expand_path(value) }
end.parse!

abort "Missing --batch" if options[:batch].to_s.empty?

batch = JSON.parse(File.read(options[:batch]))
reports = Array(batch["entries"]).map { |entry| TranscriptFidelity.report(entry, require_source: true) }
result = {
  "entries" => reports.length,
  "passed" => reports.all? { |report| report["failures"].empty? },
  "reports" => reports
}

puts JSON.pretty_generate(result)
exit(result["passed"] ? 0 : 1)
