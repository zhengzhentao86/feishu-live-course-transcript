#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: mark_minutes_corrected.rb --session state.json --minutes-id ID --batch-id ID --revision REV"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--minutes-id ID") { |value| options[:minutes_id] = value }
  parser.on("--batch-id ID") { |value| options[:batch_id] = value }
  parser.on("--revision REV") { |value| options[:revision] = value }
end.parse!

%i[session minutes_id batch_id revision].each do |key|
  abort "Missing --#{key.to_s.tr('_', '-')}" if options[key].to_s.strip.empty?
end

state = JSON.parse(File.read(options[:session]))
abort "Minutes correction can be marked only in finalizing status" unless state["status"] == "finalizing"
abort "Finalization has no start timestamp" if state["finalization_started_at"].to_s.empty?
abort "Final incremental batch has not completed" if state["final_incremental_completed_at"].to_s.empty?
abort "Minutes correction already recorded at #{state['minutes_corrected_at']}" unless state["minutes_corrected_at"].to_s.empty?
abort "Full validation already completed" unless state["full_validation_completed_at"].to_s.empty?

recorded_revision = state.dig("document", "revision").to_s
correction_revision = options[:revision].to_s
if recorded_revision.match?(/\A\d+\z/) && correction_revision.match?(/\A\d+\z/) && correction_revision.to_i < recorded_revision.to_i
  abort "Correction revision cannot be older than session revision: session=#{recorded_revision} correction=#{correction_revision}"
end

state["minutes_source_id"] = options[:minutes_id]
state["minutes_correction_batch_id"] = options[:batch_id]
state["minutes_corrected_revision"] = correction_revision
state["document"]["revision"] = correction_revision
state["minutes_corrected_at"] = Time.now.iso8601
state["updated_at"] = Time.now.iso8601

temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts "minutes_correction_recorded minutes_id=#{options[:minutes_id]} batch_id=#{options[:batch_id]} revision=#{options[:revision]}"
