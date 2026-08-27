#!/usr/bin/env ruby

require "cgi"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rexml/document"
require "time"
require_relative "session_index"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = {
  workspace: File.join(Dir.home, "Documents", "Codex", "live-course-sessions"),
  parent_position: "my_library",
  section_title: "课程正文",
  poll_interval_seconds: 120,
  event_identity: "user",
  dry_run: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: init_session.rb --course-title TITLE --chat-id ID --teacher NAME [options]"
  parser.on("--course-title TITLE") { |value| options[:course_title] = value }
  parser.on("--chat-id ID") { |value| options[:chat_id] = value }
  parser.on("--teacher NAME") { |value| options[:teacher] = value }
  parser.on("--meeting-id ID") { |value| options[:meeting_id] = value }
  parser.on("--meeting-start ISO8601") { |value| options[:meeting_start] = value }
  parser.on("--meeting-label LABEL") { |value| options[:meeting_label] = value }
  parser.on("--event-identity IDENTITY") { |value| options[:event_identity] = value }
  parser.on("--poll-interval-seconds N", Integer) { |value| options[:poll_interval_seconds] = value }
  parser.on("--photographer NAME") { |value| options[:photographer] = value }
  parser.on("--document-token TOKEN") { |value| options[:document_token] = value }
  parser.on("--document-url URL") { |value| options[:document_url] = value }
  parser.on("--workspace DIR") { |value| options[:workspace] = File.expand_path(value) }
  parser.on("--parent-position POSITION") { |value| options[:parent_position] = value }
  parser.on("--section-title TITLE") { |value| options[:section_title] = value }
  parser.on("--dry-run") { options[:dry_run] = true }
end.parse!

%i[course_title chat_id teacher].each do |key|
  abort "Missing required option --#{key.to_s.tr('_', '-')}" if options[key].to_s.strip.empty?
end
abort "--event-identity must be user or bot" unless %w[user bot].include?(options[:event_identity])
abort "--poll-interval-seconds must be between 60 and 600" unless (60..600).cover?(options[:poll_interval_seconds])

def slug(text)
  value = text.downcase.gsub(/[^\p{Han}a-z0-9]+/u, "-").gsub(/\A-|-\z/, "")
  value.empty? ? "course" : value[0, 32]
end

def parse_envelope(stdout)
  JSON.parse(stdout)
rescue JSON::ParserError
  stdout.enum_for(:scan, /\{/).map { Regexp.last_match.begin(0) }.reverse_each do |index|
    begin
      value = JSON.parse(stdout[index..])
      return value if value.is_a?(Hash)
    rescue JSON::ParserError
      next
    end
  end
  raise
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

def plain_text(node)
  node.children.map { |child| child.is_a?(REXML::Element) ? plain_text(child) : child.to_s }.join.gsub(/\s+/, " ").strip
end

now = Time.now
session_id = "#{now.strftime('%Y%m%d-%H%M%S')}-#{slug(options[:course_title])}"
session_dir = File.join(options[:workspace], session_id)
FileUtils.mkdir_p(File.join(session_dir, "runs"))
FileUtils.mkdir_p(File.join(session_dir, "batches"))
FileUtils.mkdir_p(File.join(session_dir, "validation-previews"))
FileUtils.mkdir_p(File.join(session_dir, "indexes"))

doc_title = "#{options[:course_title]}｜逐字稿 × PPT 完整对照版"
initial_xml = <<~XML
  <callout emoji="🎓" background-color="light-blue">
    <p><b>阅读方式</b>：按讲师时间戳阅读忠实精修逐字稿；有对应 PPT 时图片紧跟一组正文，没有图片时课程讲解仍会连续记录。</p>
    <p>本稿只删除口水词、逐字重复和课堂杂项，保留原讲解顺序、解释、案例、问答、数字与因果，不压缩成摘要；重点概念以蓝色加粗呈现。</p>
    <p>同一段讲解可对应一张或多张连续 PPT；正文只出现一次，图片按群内发送顺序紧跟其后。</p>
  </callout>
  <h1>课程信息</h1>
  <p><b>课程：</b>#{CGI.escapeHTML(options[:course_title])}</p>
  <p><b>讲师：</b>#{CGI.escapeHTML(options[:teacher])}</p>
  <p><b>整理规则：</b>有图时一张 PPT 对应一组忠实精修正文；无图时按 1—3 分钟窗口和语义连续追加，不把长讲解压成摘要。</p>
  <h1>#{CGI.escapeHTML(options[:section_title])}</h1>
XML

initial_path = File.join(session_dir, "initial_document.xml")
File.write(initial_path, initial_xml)

usage = <<~MARKDOWN
  # 本课程使用指引

  - PPT 请发送到课程群：`#{options[:chat_id]}`。
  - 飞书会议和实时转写保持开启#{options[:meeting_id] ? "，会议 ID：`#{options[:meeting_id]}`" : ""}。
  - 每条新图片消息都会进入文档；同页重拍也会保留。
  - 没有新图片时，会议新增讲解仍会以纯文本持续写入。
  - 只删口水词和无关杂音，保留解释、案例与原讲解顺序；内容多会拆段，不压成摘要。
  - 课中默认每 #{options[:poll_interval_seconds]} 秒检查一次，把 2—6 分钟新增内容整批一次写入、一次尾部局部回读。
  - 群消息从上次消息时间和位置继续；会议事件从上次转写结束时间或事件游标继续，不从开头拉取。
  - 默认已为本课程新建实时工作文档；整门课结束后另建按主题分章的正式成品文档，并完成首中尾视觉验收。
MARKDOWN
File.write(File.join(session_dir, "USAGE.md"), usage)

document = {
  "token" => options[:document_token],
  "url" => options[:document_url],
  "revision" => nil,
  "section_title" => options[:section_title],
  "section_block_id" => nil,
  "append_anchor_block_id" => nil
}

unless options[:dry_run]
  if options[:document_token].to_s.empty?
    stdout, stderr, status = Open3.capture3(
      CLI_ENV,
      CLI_BIN, "docs", "+create",
      "--title", doc_title,
      "--content", "@./#{File.basename(initial_path)}",
      "--doc-format", "xml",
      "--parent-position", options[:parent_position],
      "--as", "user",
      "--format", "json",
      chdir: session_dir
    )
    payload = parse_envelope(stdout)
    unless status.success? && payload["ok"] == true
      error = payload["error"] || {}
      abort "lark-cli docs +create failed: #{error['code']} #{error['message']}\n#{stderr.lines.last(5).join}"
    end
    document["token"] = find_value(payload, %w[document_token doc_token obj_token token])
    document["url"] = find_value(payload, %w[url document_url])
    document["revision"] = find_value(payload, %w[revision_id revision])
    abort "Document created but response did not contain a document token" if document["token"].to_s.empty?
  end

  # Resolve the section/tail anchor once during setup. Live polling can then use
  # optimistic revision writes without fetching the full document first.
  fetch_stdout, fetch_stderr, fetch_status = Open3.capture3(
    CLI_ENV,
    CLI_BIN, "docs", "+fetch",
    "--doc", document["token"],
    "--doc-format", "xml",
    "--detail", "with-ids",
    "--scope", "outline",
    "--as", "user",
    "--format", "json",
    chdir: session_dir
  )
  fetch_payload = parse_envelope(fetch_stdout)
  unless fetch_status.success? && fetch_payload["ok"] == true
    error = fetch_payload["error"] || {}
    abort "Document created but anchor fetch failed: #{error['code']} #{error['message']}\n#{fetch_stderr.lines.last(5).join}"
  end
  fetched_document = fetch_payload.dig("data", "document") || abort("Anchor fetch response has no document")
  outline_xml = REXML::Document.new("<root>#{fetched_document.fetch('content')}</root>")
  heading = REXML::XPath.match(outline_xml, "//h1").find { |node| plain_text(node) == options[:section_title] }
  abort "Could not resolve initial section heading: #{options[:section_title]}" unless heading
  document["revision"] = fetched_document["revision_id"]
  document["section_block_id"] = heading.attributes["id"].to_s
  document["append_anchor_block_id"] = heading.attributes["id"].to_s
end

meeting_sessions = if options[:meeting_id]
  [{
    "meeting_id" => options[:meeting_id],
    "label" => options[:meeting_label] || "第1场",
    "start_time" => options[:meeting_start],
    "end_time" => nil,
    "status" => "active",
    "event_identity" => options[:event_identity]
  }]
else
  []
end

state = {
  "version" => 5,
  "session_id" => session_id,
  "status" => options[:dry_run] ? "dry_run" : "active",
  "finalization_started_at" => nil,
  "final_incremental_completed_at" => nil,
  "minutes_corrected_at" => nil,
  "minutes_source_id" => nil,
  "minutes_correction_batch_id" => nil,
  "minutes_corrected_revision" => nil,
  "full_validation_completed_at" => nil,
  "finalized_at" => nil,
  "course_title" => options[:course_title],
  "chat_id" => options[:chat_id],
  "meeting_ids" => options[:meeting_id] ? [options[:meeting_id]] : [],
  "meeting_sessions" => meeting_sessions,
  "current_meeting_id" => options[:meeting_id],
  "course_start" => options[:meeting_start],
  "meeting_start" => options[:meeting_start],
  "event_identity" => options[:event_identity],
  "teacher" => options[:teacher],
  "speaker_mode" => "single_teacher",
  "speaker_map" => {},
  "photographer" => options[:photographer],
  "consent" => {
    "scope" => ["课程群 PPT 图片", "对应会议或妙记课程转写", "讲师姓名"],
    "target" => "新建飞书云文档",
    "confirmed" => !options[:dry_run],
    "confirmed_at" => options[:dry_run] ? nil : now.iso8601
  },
  "document" => document,
  "last_message_time" => nil,
  "last_message_scan_end" => options[:meeting_start],
  "last_message_position" => nil,
  "processed_message_ids" => [],
  "processed_image_keys" => [],
  "processed_transcript_ids" => [],
  "ignored_transcript_ids" => [],
  "processed_segment_ids" => [],
  "indexes" => {
    "processed_message_ids" => "indexes/processed_message_ids.txt",
    "processed_image_keys" => "indexes/processed_image_keys.txt",
    "processed_transcript_ids" => "indexes/processed_transcript_ids.txt",
    "ignored_transcript_ids" => "indexes/ignored_transcript_ids.txt",
    "processed_segment_ids" => "indexes/processed_segment_ids.txt"
  },
  "index_counts" => SessionIndex::FIELDS.each_with_object({}) { |field, memo| memo[field] = 0 },
  "ignored_transcript_records" => [],
  "last_transcript_end_ms" => nil,
  "last_transcript_end_time" => options[:meeting_start],
  "last_transcript_scan_end_ms" => nil,
  "meeting_event_page_token" => nil,
  "meeting_status" => "active",
  "formal_minutes_available" => false,
  "poll_interval_seconds" => options[:poll_interval_seconds],
  "batch_target_seconds" => options[:poll_interval_seconds],
  "batch_max_seconds" => [options[:poll_interval_seconds] * 3, 600].min,
  "last_poll_completed_at" => nil,
  "last_batch_completed_at" => nil,
  "transcript_blocks" => [],
  "accepted_slides" => [],
  "content_groups" => [],
  "current_chapter" => nil,
  "chapter_history" => [],
  "unavailable_image_records" => [],
  "last_course_time_ms" => nil,
  "requires_document_rebuild" => false,
  "review_queue" => [],
  "created_at" => now.iso8601,
  "updated_at" => now.iso8601
}

SessionIndex::FIELDS.each { |field| File.write(File.join(session_dir, "indexes", "#{field}.txt"), "") }
File.write(File.join(session_dir, "state.json"), JSON.pretty_generate(state) + "\n")
puts JSON.pretty_generate({
  "session_dir" => session_dir,
  "state_path" => File.join(session_dir, "state.json"),
  "document" => document,
  "dry_run" => options[:dry_run]
})
