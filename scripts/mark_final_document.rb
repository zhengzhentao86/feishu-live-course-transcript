#!/usr/bin/env ruby

require "json"
require "optparse"
require "time"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: mark_final_document.rb --session state.json --token TOKEN --revision REVISION [--url URL]"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--token TOKEN") { |value| options[:token] = value }
  parser.on("--revision REVISION", Integer) { |value| options[:revision] = value }
  parser.on("--url URL") { |value| options[:url] = value }
end.parse!
%i[session token revision].each { |key| abort "Missing --#{key}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
abort "Final document can only be bound during finalizing" unless state["status"] == "finalizing"
abort "Final document already bound" if state["final_document"].is_a?(Hash) && !state.dig("final_document", "token").to_s.empty?

state["final_document"] = {
  "token" => options[:token],
  "url" => options[:url],
  "revision" => options[:revision],
  "bound_at" => Time.now.iso8601
}
state["updated_at"] = Time.now.iso8601
temp_path = options[:session] + ".tmp"
File.write(temp_path, JSON.pretty_generate(state) + "\n")
File.rename(temp_path, options[:session])
puts JSON.pretty_generate({ "ok" => true, "final_document" => state["final_document"] })
