#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"
require "time"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = { event_identity: "user", join_bot: false, yes: false, now: Time.now }
OptionParser.new do |parser|
  parser.banner = "Usage: course_preflight.rb --chat-id ID [--meeting-id ID | --meeting-number N] [options]"
  parser.on("--chat-id ID") { |value| options[:chat_id] = value }
  parser.on("--meeting-id ID") { |value| options[:meeting_id] = value }
  parser.on("--meeting-number N") { |value| options[:meeting_number] = value }
  parser.on("--course-start ISO8601") { |value| options[:course_start] = Time.parse(value) }
  parser.on("--event-identity IDENTITY") { |value| options[:event_identity] = value }
  parser.on("--join-bot") { options[:join_bot] = true }
  parser.on("--yes") { options[:yes] = true }
  parser.on("--now ISO8601") { |value| options[:now] = Time.parse(value) }
end.parse!

abort "Missing --chat-id" if options[:chat_id].to_s.empty?
abort "--event-identity must be user or bot" unless %w[user bot].include?(options[:event_identity])
if options[:join_bot]
  abort "--join-bot requires --yes because joining is visible to participants" unless options[:yes]
  abort "--join-bot requires a 9-digit --meeting-number" unless options[:meeting_number].to_s.match?(/\A\d{9}\z/)
end

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
  nil
end

def safe_error(payload, stderr)
  error = payload.is_a?(Hash) ? payload["error"] || {} : {}
  text = [error["code"], error["message"], stderr.lines.last(3).join].compact.join(" ")
  text.gsub(%r{https?://\S+}, "[url]").gsub(/[A-Za-z0-9_-]{32,}/, "[redacted]").strip
end

def run_cli(*args)
  stdout, stderr, cmd_status = Open3.capture3(CLI_ENV, CLI_BIN, *args)
  payload = parse_envelope(stdout)
  [cmd_status.success? && payload.is_a?(Hash) && payload["ok"] == true, payload, safe_error(payload, stderr)]
end

checks = {}
chat_ok, _chat_payload, chat_error = run_cli(
  "im", "+chat-members-list", "--chat-id", options[:chat_id],
  "--member-types", "user,bot", "--page-all", "--as", "user", "--format", "json"
)
checks["chat_readable"] = { "ok" => chat_ok, "error" => chat_ok ? nil : chat_error }

meeting_id = options[:meeting_id].to_s
if options[:join_bot]
  join_ok, join_payload, join_error = run_cli(
    "vc", "+meeting-join", "--as", "bot", "--meeting-number", options[:meeting_number], "--format", "json"
  )
  unless join_ok
    result = {
      "action" => join_error.include?("允许智能体加入会议") ? "enable_independent_agent_join" : "fix_bot_join",
      "ready" => false,
      "checks" => checks.merge("bot_join" => { "ok" => false, "error" => join_error })
    }
    puts JSON.pretty_generate(result)
    exit 2
  end
  meeting_id = join_payload.dig("data", "meeting", "id").to_s
  meeting_id = join_payload.dig("meeting", "id").to_s if meeting_id.empty?
  abort "Bot joined but response did not contain meeting.id" if meeting_id.empty?
  options[:event_identity] = "bot"
  checks["bot_join"] = { "ok" => true, "meeting_id" => meeting_id }
end

if meeting_id.empty?
  active_ok, active_payload, active_error = run_cli(
    "vc", "+meeting-list-active", "--as", "user", "--format", "json"
  )
  unless active_ok
    checks["active_meeting_discovery"] = { "ok" => false, "error" => active_error }
    puts JSON.pretty_generate({ "action" => "fix_active_meeting_discovery", "ready" => false, "checks" => checks })
    exit 2
  end
  meetings = Array(active_payload.dig("data", "meetings") || active_payload["meetings"] || active_payload.dig("data", "items"))
  if options[:meeting_number]
    meetings = meetings.select { |meeting| (meeting["meeting_no"] || meeting["meeting_number"]).to_s == options[:meeting_number].to_s }
  end
  if meetings.length != 1
    checks["active_meeting_discovery"] = {
      "ok" => false,
      "candidate_count" => meetings.length,
      "candidates" => meetings.map { |meeting| meeting.slice("meeting_id", "meeting_no", "meeting_title", "topic") }
    }
    action = meetings.empty? ? "no_active_meeting" : "choose_active_meeting"
    puts JSON.pretty_generate({ "action" => action, "ready" => false, "checks" => checks })
    exit 2
  end
  meeting = meetings.first
  meeting_id = (meeting["meeting_id"] || meeting["id"]).to_s
  abort "Active meeting response has no meeting_id" if meeting_id.empty?
  checks["active_meeting_discovery"] = { "ok" => true, "meeting_id" => meeting_id }
end

window_start = (options[:course_start] || (options[:now] - 180)).iso8601
events_ok, events_payload, events_error = run_cli(
  "vc", "+meeting-events", "--meeting-id", meeting_id,
  "--start", window_start, "--end", options[:now].iso8601,
  "--page-all", "--as", options[:event_identity], "--format", "json"
)
unless events_ok
  action = if events_error.include?("允许智能体加入会议")
             "enable_independent_agent_join"
           elsif events_error.match?(/permission|scope|权限/i)
             "authorize_meeting_events"
           else
             "fix_meeting_event_access"
           end
  checks["meeting_events"] = { "ok" => false, "error" => events_error }
  puts JSON.pretty_generate({ "action" => action, "ready" => false, "meeting_id" => meeting_id, "checks" => checks })
  exit 2
end

events = Array(events_payload.dig("data", "events") || events_payload["events"])
transcript_items = events.select { |event| event["event_type"] == "transcript_received" }
  .flat_map { |event| Array(event.dig("payload", "transcript_received_items")) }
  .select { |item| !item["text"].to_s.strip.empty? }
checks["meeting_events"] = { "ok" => true, "event_count" => events.length }
checks["live_transcript_sample"] = { "ok" => !transcript_items.empty?, "sample_count" => transcript_items.length }

transcript_event_times = events.select { |event| event["event_type"] == "transcript_received" }.map do |event|
  Time.parse(event["event_time"].to_s)
rescue ArgumentError
  nil
end.compact
earliest_transcript_event = transcript_event_times.min
late_start = options[:course_start] && (options[:now] - options[:course_start]) > 600 &&
  (earliest_transcript_event.nil? || earliest_transcript_event > options[:course_start] + 180)
checks["course_start_window"] = {
  "ok" => !late_start,
  "course_age_seconds" => options[:course_start] ? (options[:now] - options[:course_start]).round : nil,
  "earliest_transcript_event" => earliest_transcript_event&.iso8601,
  "requires_minutes_backfill" => late_start
}
ready = chat_ok && !transcript_items.empty? && !late_start
action = if !chat_ok
           "fix_chat_access"
         elsif late_start
           "late_start_requires_minutes_backfill"
         elsif transcript_items.empty?
           "wait_for_live_transcript_sample"
         else
           "ready"
         end

puts JSON.pretty_generate({
  "action" => action,
  "ready" => ready,
  "meeting_id" => meeting_id,
  "event_identity" => options[:event_identity],
  "checked_at" => options[:now].iso8601,
  "checks" => checks
})
exit(ready ? 0 : 2)
