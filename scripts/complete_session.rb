#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: complete_session.rb --session state.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
end.parse!
abort "Missing --session" if options[:session].to_s.empty?

state = JSON.parse(File.read(options[:session]))
abort "Session must be finalizing before completion" unless state["status"] == "finalizing"
abort "Final document is missing" if state.dig("final_document", "token").to_s.empty?
abort "Final validation has not passed" if state["full_validation_completed_at"].to_s.empty?
abort "Minutes correction has not completed" if state["minutes_corrected_at"].to_s.empty?

now = Time.now.iso8601
state["status"] = "completed"
state["meeting_status"] = "ended"
state["finalized_at"] = now
state["updated_at"] = now
temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts JSON.pretty_generate({
  "ok" => true,
  "status" => "completed",
  "finalized_at" => now,
  "document_url" => state.dig("final_document", "url"),
  "document_token" => state.dig("final_document", "token")
})
