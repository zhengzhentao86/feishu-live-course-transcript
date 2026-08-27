#!/usr/bin/env ruby

require "cgi"
require "json"
require "open3"
require "optparse"
require "rexml/document"
require "set"
require "time"
require_relative "transcript_fidelity"
require_relative "session_index"

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze
CLI_BIN = ENV.fetch("LARK_CLI_BIN", "lark-cli").freeze

options = { dry_run: false, allow_missing_images: false, recover_existing: false }
OptionParser.new do |parser|
  parser.banner = "Usage: append_batch.rb --session state.json --batch batch.json [--dry-run-output output.xml]"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--batch FILE") { |value| options[:batch] = File.expand_path(value) }
  parser.on("--dry-run-output FILE") { |value| options[:dry_run_output] = File.expand_path(value); options[:dry_run] = true }
  parser.on("--allow-missing-images") { options[:allow_missing_images] = true }
  parser.on("--recover-existing") { options[:recover_existing] = true }
end.parse!

%i[session batch].each { |key| abort "Missing --#{key}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
session_dir = File.dirname(options[:session])

unless options[:dry_run]
  status = state["status"].to_s
  if status == "completed"
    puts "session_completed added=0 cloud_writes=0 cloud_readbacks=0"
    exit 0
  end
  abort "Session status does not allow incremental append: #{status}" unless %w[active finalizing].include?(status)
  if status == "finalizing"
    abort "Finalization has no start timestamp" if state["finalization_started_at"].to_s.empty?
    abort "Final incremental batch already completed at #{state['final_incremental_completed_at']}" unless state["final_incremental_completed_at"].to_s.empty?
    abort "Minutes correction already started or completed" unless state["minutes_corrected_at"].to_s.empty?
  end
end

batch = JSON.parse(File.read(options[:batch]))
doc_token = state.dig("document", "token").to_s
section_title = state.dig("document", "section_title").to_s
section_title = "课程正文" if section_title.empty?
abort "Session has no document token; use --dry-run-output or initialize a live session" if doc_token.empty? && !options[:dry_run]

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
  stdout, stderr, cmd_status = Open3.capture3(CLI_ENV, CLI_BIN, *args, chdir: chdir)
  payload = parse_envelope(stdout)
  unless cmd_status.success? && payload["ok"] == true
    error = payload["error"] || {}
    abort "lark-cli failed: #{error['code']} #{error['message']}\n#{stderr.lines.last(5).join}"
  end
  payload
end

def plain_text(node)
  node.children.map { |child| child.is_a?(REXML::Element) ? plain_text(child) : child.to_s }.join.gsub(/\s+/, " ").strip
end

def nodes_including_self(block, name)
  nodes = []
  nodes << block if block.name == name
  nodes.concat(REXML::XPath.match(block, ".//#{name}"))
  nodes
end

def section_heading(document, title)
  xml = REXML::Document.new("<root>#{document.fetch('content')}</root>")
  REXML::XPath.each(xml, "//h1") do |node|
    return node.attributes["id"].to_s if plain_text(node) == title
  end
  nil
end

def rich_text(text)
  text.split(/(\[\[[^\]]+\]\])/).map do |part|
    if part.start_with?("[[") && part.end_with?("]]" )
      %Q(<b><span text-color="rgb(36,91,219)">#{CGI.escapeHTML(part[2...-2])}</span></b>)
    else
      CGI.escapeHTML(part)
    end
  end.join
end

def entry_kind(entry)
  kind = entry["kind"].to_s
  kind = entry["local_path"].to_s.empty? ? "text" : "image" if kind.empty?
  abort "Unsupported entry kind: #{kind}" unless %w[image image_group text].include?(kind)
  kind
end

def entry_images(entry)
  return [] if entry_kind(entry) == "text"
  return Array(entry["images"]) if entry_kind(entry) == "image_group"
  [entry]
end

def clean_paragraphs(entry)
  report = TranscriptFidelity.report(entry, require_source: true)
  unless report["failures"].empty?
    abort "Transcript fidelity failed at #{report['label']}: #{report['failures'].join('; ')}"
  end
  TranscriptFidelity.paragraphs(entry)
end

def meeting_stamp(entry)
  start_time = (entry["course_time"] || entry.fetch("meeting_time")).to_s
  abort "Invalid meeting_time: #{start_time}" unless start_time.match?(/\A\d{2}:\d{2}:\d{2}\z/)
  end_time = (entry["course_end_time"] || entry["meeting_end_time"]).to_s
  if !end_time.empty? && !end_time.match?(/\A\d{2}:\d{2}:\d{2}\z/)
    abort "Invalid meeting_end_time: #{end_time}"
  end
  range = end_time.empty? || end_time == start_time ? start_time : "#{start_time}–#{end_time}"
  "#{entry.fetch('speaker')} · #{range}"
end

def meeting_seconds(value)
  parts = value.to_s.split(":").map(&:to_i)
  return 0 unless parts.length == 3
  (parts[0] * 3600) + (parts[1] * 60) + parts[2]
end

def sort_key(entry)
  explicit = entry["timeline_ms"] || entry["transcript_start_ms"]
  return [explicit.to_i, entry_kind(entry) == "text" ? 1 : 0] unless explicit.nil?
  [meeting_seconds(entry["meeting_time"]) * 1000, entry_kind(entry) == "text" ? 1 : 0]
end

def relative_image_path(path, session_dir)
  absolute = File.expand_path(path, session_dir)
  prefix = session_dir.end_with?(File::SEPARATOR) ? session_dir : session_dir + File::SEPARATOR
  abort "Image must be inside the session directory: #{absolute}" unless absolute.start_with?(prefix)
  [absolute, absolute.delete_prefix(prefix)]
end

def grid_widths(count)
  case count
  when 1 then [["1.0"], 780]
  when 2 then [["0.5", "0.5"], 360]
  when 3 then [["0.333333", "0.333333", "0.333334"], 240]
  when 4 then [["0.25", "0.25", "0.25", "0.25"], 180]
  else abort "Grid row must contain 1-4 images"
  end
end

def image_xml(image, entry, session_dir, allow_missing_images:, width:)
  absolute, relative = relative_image_path(image.fetch("local_path"), session_dir)
  unless allow_missing_images
    abort "Image missing: #{absolute}" unless File.file?(absolute) && File.size(absolute).positive?
  end
  sent = image.fetch("sent_at").to_s
  sent_label = begin
    Time.iso8601(sent).strftime("%H:%M")
  rescue ArgumentError
    sent
  end
  title = image["slide_title"].to_s.empty? ? "标题待识别" : image["slide_title"].to_s
  display_time = entry["course_time"] || entry.fetch("meeting_time")
  caption = "PPT｜群内发送 #{sent_label}｜课程约 #{display_time}｜#{title}"
  image_name = "#{image.fetch('position').to_i.to_s.rjust(4, '0')}-#{image.fetch('message_id')}-#{File.basename(absolute)}"
  %Q(<img path="@./#{CGI.escapeHTML(relative)}" width="#{width}" name="#{CGI.escapeHTML(image_name)}" caption="#{CGI.escapeHTML(caption)}"/>)
end

def entry_xml(entry, session_dir, allow_missing_images: false)
  abort "Missing speaker" if entry["speaker"].to_s.empty?
  paragraphs = clean_paragraphs(entry)
  stamp = meeting_stamp(entry)
  base = [
    %Q(<p><b>#{CGI.escapeHTML(stamp)}</b></p>),
    *paragraphs.map { |paragraph| %Q(<p>#{rich_text(paragraph)}</p>) }
  ]
  return base.join("\n") if entry_kind(entry) == "text"

  images = entry_images(entry)
  if entry_kind(entry) == "image"
    base << image_xml(images.first, entry, session_dir, allow_missing_images: allow_missing_images, width: 780)
  else
    images.each_slice(4) do |row|
      ratios, width = grid_widths(row.length)
      columns = row.each_with_index.map do |image, index|
        tag = image_xml(image, entry, session_dir, allow_missing_images: allow_missing_images, width: width)
        %Q(<column width-ratio="#{ratios[index]}">#{tag}</column>)
      end
      base << "<grid>#{columns.join}</grid>"
    end
  end
  base.join("\n")
end

session_index = SessionIndex.new(options[:session], state)
processed_message_ids = session_index.values("processed_message_ids")
processed_image_keys = session_index.values("processed_image_keys")
processed_transcript_ids = session_index.values("processed_transcript_ids")
processed_segment_ids = session_index.values("processed_segment_ids")

entries = Array(batch["entries"]).reject do |entry|
  if %w[image image_group].include?(entry_kind(entry))
    images = entry_images(entry)
    processed = images.count do |image|
      processed_message_ids.include?(image["message_id"]) || processed_image_keys.include?(image["image_key"])
    end
    abort "Image group partially overlaps processed images; rebuild the group before append" if processed.positive? && processed < images.length
    processed == images.length
  else
    segment_id = entry.fetch("segment_id").to_s
    ids = Array(entry["transcript_ids"]).map(&:to_s).reject(&:empty?)
    processed_count = processed_transcript_ids.intersection(Set.new(ids)).length
    if processed_count.positive? && processed_count < ids.length
      abort "Text segment partially overlaps processed transcript IDs: #{segment_id}; split the batch entry first"
    end
    processed_segment_ids.include?(segment_id) || (!ids.empty? && processed_count == ids.length)
  end
end.sort_by { |entry| sort_key(entry) }

course_values = entries.map { |entry| entry["course_time_ms"] }.compact.map(&:to_i)
if state["last_course_time_ms"] && !course_values.empty? && course_values.min < state["last_course_time_ms"].to_i
  abort "historical_backfill_requires_rebuild: new course time is earlier than the verified document tail"
end

chapter_cursor = state["current_chapter"].to_s
opened_chapters = []
xml_chunks = entries.map do |entry|
  chunks = []
  chapter = entry["chapter_title"].to_s.strip
  if !chapter.empty? && chapter != chapter_cursor
    chunks << %Q(<h2>#{CGI.escapeHTML(chapter)}</h2>)
    chapter_cursor = chapter
    opened_chapters << { "title" => chapter, "opened_at_course_time_ms" => entry["course_time_ms"] || entry["transcript_start_ms"] }
  end
  chunks << entry_xml(entry, session_dir, allow_missing_images: options[:allow_missing_images])
  chunks.join("\n")
end
if options[:dry_run]
  output = ["<h1>#{CGI.escapeHTML(section_title)}</h1>", *xml_chunks].join("\n") + "\n"
  output_path = options[:dry_run_output] || File.join(session_dir, "dry-run-output.xml")
  File.write(output_path, output)
  puts JSON.pretty_generate({
    "dry_run" => true,
    "entries" => entries.length,
    "image_entries" => entries.sum { |entry| entry_images(entry).length },
    "text_entries" => entries.count { |entry| entry_kind(entry) == "text" },
    "output" => output_path
  })
  exit 0
end

def fetch_document(doc_token, session_dir, scope:, start_block_id: nil, end_block_id: nil, revision_id: nil)
  args = [
    "docs", "+fetch", "--doc", doc_token,
    "--doc-format", "xml", "--detail", "full", "--scope", scope,
    "--as", "user", "--format", "json"
  ]
  args += ["--start-block-id", start_block_id] if start_block_id
  args += ["--end-block-id", end_block_id] if end_block_id
  args += ["--revision-id", revision_id.to_s] if revision_id
  run_cli(*args, chdir: session_dir).dig("data", "document") || abort("Fetch response has no document")
end

def append_xml(doc_token, content, revision, session_dir)
  data = run_cli(
    "docs", "+update", "--doc", doc_token,
    "--command", "append", "--content", content,
    "--revision-id", revision.to_s,
    "--as", "user", "--format", "json",
    chdir: session_dir
  ).fetch("data")
  abort "Unexpected update result: #{data.inspect}" unless data["result"] == "success" && Array(data["warnings"]).empty?
  data.dig("document", "revision_id") || abort("Update response has no revision")
end

state["transcript_blocks"] ||= []
state["accepted_slides"] ||= []
state["content_groups"] ||= []
state["chapter_history"] ||= []
state["unavailable_image_records"] ||= []
state["ignored_transcript_records"] ||= []

def persist_state(path, state)
  state["updated_at"] = Time.now.iso8601
  temp_path = path + ".tmp"
  File.write(temp_path, JSON.pretty_generate(state) + "\n")
  File.rename(temp_path, path)
end

def apply_poll_cursors(state, batch)
  poll = batch["poll"] || {}
  if poll["last_message_position"]
    next_position = poll["last_message_position"].to_i
    current_position = state["last_message_position"].to_i
    abort "Message position cannot move backwards" if next_position < current_position
    state["last_message_position"] = next_position
  end
  unless poll["last_message_time"].to_s.empty?
    begin
      next_message_time = Time.parse(poll["last_message_time"])
      current_message_time = state["last_message_time"].to_s.empty? ? nil : Time.parse(state["last_message_time"])
    rescue ArgumentError
      abort "Invalid last_message_time"
    end
    abort "Message time cannot move backwards" if current_message_time && next_message_time < current_message_time
    state["last_message_time"] = next_message_time.iso8601
  end
  next_scan_end_value = poll["last_message_scan_end"] || poll["message_scan_end"]
  unless next_scan_end_value.to_s.empty?
    begin
      next_scan_end = Time.iso8601(next_scan_end_value)
      current_scan_end = state["last_message_scan_end"].to_s.empty? ? nil : Time.iso8601(state["last_message_scan_end"])
    rescue ArgumentError
      abort "Invalid ISO 8601 message scan cursor"
    end
    abort "Message scan cursor cannot move backwards" if current_scan_end && next_scan_end < current_scan_end
    state["last_message_scan_end"] = next_scan_end.iso8601
  end
  if poll["transcript_scan_end_ms"]
    state["last_transcript_scan_end_ms"] = [state["last_transcript_scan_end_ms"].to_i, poll["transcript_scan_end_ms"].to_i].max
  end
  if poll["last_transcript_end_ms"]
    state["last_transcript_end_ms"] = [state["last_transcript_end_ms"].to_i, poll["last_transcript_end_ms"].to_i].max
  end
  unless poll["last_transcript_end_time"].to_s.empty?
    begin
      next_transcript_time = Time.parse(poll["last_transcript_end_time"])
      current_transcript_time = state["last_transcript_end_time"].to_s.empty? ? nil : Time.parse(state["last_transcript_end_time"])
    rescue ArgumentError
      abort "Invalid last_transcript_end_time"
    end
    abort "Transcript end time cannot move backwards" if current_transcript_time && next_transcript_time < current_transcript_time
    state["last_transcript_end_time"] = next_transcript_time.iso8601
  end
  if poll.key?("meeting_event_page_token")
    token = poll["meeting_event_page_token"].to_s
    state["meeting_event_page_token"] = token.empty? ? nil : token
  end
end

ignored_ids = Array(batch["ignored_transcripts"]).flat_map { |item| Array(item["transcript_ids"]) }.map(&:to_s).reject(&:empty?)

if entries.empty?
  state["ignored_transcript_records"] += Array(batch["ignored_transcripts"])
  state["unavailable_image_records"] = (state["unavailable_image_records"] + Array(batch["unavailable_images"])).uniq { |item| item["message_id"] }
  apply_poll_cursors(state, batch)
  state["last_poll_completed_at"] = Time.now.iso8601
  state["final_incremental_completed_at"] = Time.now.iso8601 if state["status"] == "finalizing"
  persist_state(options[:session], state)
  session_index.append("ignored_transcript_ids", ignored_ids)
  session_index.append("processed_transcript_ids", ignored_ids)
  session_index.configure_state!
  persist_state(options[:session], state)
  puts "batch_noop added=0 cloud_writes=0 cloud_readbacks=0"
  exit 0
end

recorded_revision = state.dig("document", "revision")
abort "Session document has no recorded revision" if recorded_revision.nil?
anchor_id = state.dig("document", "append_anchor_block_id").to_s
abort "Session has no tail anchor; run migrate_session_v3.rb before the live polling hot path" if anchor_id.empty?

batch_xml = xml_chunks.join("\n")
if options[:recover_existing]
  verified = fetch_document(
    doc_token,
    session_dir,
    scope: "range",
    start_block_id: anchor_id,
    end_block_id: "-1"
  )
  revision = verified.fetch("revision_id")
  abort "Recovery revision did not advance" unless revision.to_i > recorded_revision.to_i
else
  revision = append_xml(doc_token, batch_xml, recorded_revision, session_dir)
  sleep 1
  verified = fetch_document(
    doc_token,
    session_dir,
    scope: "range",
    start_block_id: anchor_id,
    end_block_id: "-1",
    revision_id: revision
  )
end
abort "Revision drift after batch append" unless verified.fetch("revision_id").to_s == revision.to_s

xml = REXML::Document.new("<root>#{verified.fetch('content')}</root>")
paragraphs = REXML::XPath.match(xml, "//p")
new_anchor_id = anchor_id
verified_new_images = 0
index_additions = SessionIndex::FIELDS.each_with_object({}) { |field, memo| memo[field] = [] }

entries.each do |entry|
  kind = entry_kind(entry)
  body_paragraphs = clean_paragraphs(entry)
  stamp = meeting_stamp(entry)
  stamp_nodes = paragraphs.select { |node| plain_text(node) == stamp }
  body_texts = body_paragraphs.map { |body| body.gsub(/\[\[|\]\]/, "") }
  body_nodes = body_texts.map { |body_text| paragraphs.select { |node| plain_text(node) == body_text } }
  abort "Timestamp verification failed: #{stamp}" if stamp_nodes.empty?
  missing_body = body_texts.zip(body_nodes).find { |_text, nodes| nodes.empty? }
  abort "Transcript body verification failed: #{missing_body[0][0, 40]}" if missing_body

  verified_images = []
  if %w[image image_group].include?(kind)
    entry_images(entry).each do |image|
      requested_name = "#{image.fetch('position').to_i.to_s.rjust(4, '0')}-#{image.fetch('message_id')}-#{File.basename(image.fetch('local_path'))}"
      uploaded_basename = File.basename(image.fetch("local_path"))
      accepted_names = [requested_name, uploaded_basename].uniq
      matches = REXML::XPath.match(xml, "//img").select { |node| accepted_names.include?(node.attributes["name"].to_s) }
      abort "Image verification failed for #{requested_name}" unless matches.length == 1
      resource_ok = %w[token src url href].any? { |attribute| !matches.first.attributes[attribute].to_s.empty? }
      abort "Image resource missing for #{requested_name}" unless resource_ok
      image_name = matches.first.attributes["name"].to_s
      new_anchor_id = matches.first.attributes["id"].to_s
      verified_new_images += 1
      verified_images << [image, image_name]
    end
  else
    new_anchor_id = body_nodes.last.last.attributes["id"].to_s
  end

  transcript_ids = Array(entry["transcript_ids"]).map(&:to_s).reject(&:empty?)
  index_additions["processed_transcript_ids"].concat(transcript_ids)
  transcript_end_ms = entry["transcript_end_ms"]
  if transcript_end_ms
    state["last_transcript_end_ms"] = [state["last_transcript_end_ms"].to_i, transcript_end_ms.to_i].max
  end

  group_id = entry["group_id"].to_s
  group_id = entry["segment_id"].to_s if group_id.empty?
  group_id = "#{entry['meeting_id']}:#{entry['course_time_ms'] || entry['transcript_start_ms']}:#{transcript_ids.first}" if group_id.empty?
  index_additions["processed_segment_ids"] << group_id
  state["content_groups"] << {
    "group_id" => group_id,
    "kind" => kind,
    "layout" => entry["layout"] || (kind == "image_group" ? "grid" : kind == "image" ? "single" : nil),
    "alignment_mode" => entry["alignment_mode"],
    "alignment_reason" => entry["alignment_reason"],
    "meeting_id" => entry["meeting_id"],
    "meeting_label" => entry["meeting_label"],
    "meeting_time" => entry["meeting_time"],
    "meeting_end_time" => entry["meeting_end_time"],
    "course_time" => entry["course_time"] || entry["meeting_time"],
    "course_end_time" => entry["course_end_time"] || entry["meeting_end_time"],
    "course_time_ms" => entry["course_time_ms"] || entry["transcript_start_ms"],
    "course_end_time_ms" => entry["course_end_time_ms"] || entry["transcript_end_ms"],
    "speaker" => entry["speaker"],
    "chapter_title" => entry["chapter_title"],
    "paragraphs" => body_texts,
    "source_text" => entry["source_text"],
    "transcript_ids" => transcript_ids,
    "image_message_ids" => verified_images.map { |image, _name| image["message_id"] },
    "image_names" => verified_images.map { |_image, name| name }
  }
  if %w[image image_group].include?(kind)
    verified_images.each_with_index do |(image, image_name), index|
      index_additions["processed_message_ids"] << image.fetch("message_id")
      index_additions["processed_image_keys"] << image.fetch("image_key") unless image["image_key"].to_s.empty?
      state["accepted_slides"] << {
        "message_id" => image.fetch("message_id"),
        "image_key" => image["image_key"],
        "position" => image["position"],
        "sent_at" => image["sent_at"],
        "meeting_id" => entry["meeting_id"],
        "meeting_label" => entry["meeting_label"],
        "meeting_time" => entry["meeting_time"],
        "course_time" => entry["course_time"] || entry["meeting_time"],
        "course_time_ms" => entry["course_time_ms"] || entry["transcript_start_ms"],
        "slide_title" => image["slide_title"],
        "image_name" => image_name,
        "local_path" => image["local_path"],
        "content_group_id" => group_id,
        "layout" => entry["layout"] || (kind == "image_group" ? "grid" : "single"),
        "paragraphs" => body_texts,
        "text" => body_texts.join("\n"),
        "source_text" => entry["source_text"],
        "transcript_ids" => index.zero? ? transcript_ids : [],
        "transcript_end_ms" => transcript_end_ms,
        "ocr_text" => image["ocr_text"],
        "normalized_ocr" => image["normalized_ocr"]
      }
      state["last_message_position"] = [state["last_message_position"].to_i, image["position"].to_i].max
      state["last_message_time"] = [state["last_message_time"], image["sent_at"]].compact.max
    end
  else
    segment_id = entry.fetch("segment_id").to_s
    state["transcript_blocks"] << {
      "segment_id" => segment_id,
      "transcript_ids" => transcript_ids,
      "transcript_end_ms" => transcript_end_ms,
      "meeting_time" => entry["meeting_time"],
      "meeting_end_time" => entry["meeting_end_time"],
      "speaker" => entry["speaker"],
      "paragraphs" => body_texts,
      "text" => body_texts.join("\n"),
      "source_text" => entry["source_text"],
      "stamp_block_id" => stamp_nodes.last.attributes["id"].to_s,
      "body_block_ids" => body_nodes.map { |nodes| nodes.last.attributes["id"].to_s },
      "body_block_id" => body_nodes.last.last.attributes["id"].to_s
    }
  end
end

if options[:recover_existing]
  root = xml.root
  recovery_container = root.elements["fragment"] || root
  top_level = recovery_container.elements.to_a
  abort "Recovery range does not start at the recorded tail anchor" unless top_level.first&.attributes&.[]("id").to_s == anchor_id
  tail_blocks = top_level.drop(1)
  expected_paragraphs = entries.flat_map do |entry|
    [meeting_stamp(entry), *clean_paragraphs(entry).map { |body| body.gsub(/\[\[|\]\]/, "") }]
  end
  actual_paragraphs = tail_blocks.flat_map { |block| nodes_including_self(block, "p") }.map { |node| plain_text(node) }
  actual_headings = tail_blocks.flat_map { |block| nodes_including_self(block, "h2") }.map { |node| plain_text(node) }
  expected_headings = opened_chapters.map { |chapter| chapter.fetch("title") }
  actual_images = tail_blocks.flat_map { |block| nodes_including_self(block, "img") }
  expected_image_count = entries.sum { |entry| entry_images(entry).length }
  abort "Recovery transcript structure mismatch" unless actual_paragraphs == expected_paragraphs
  abort "Recovery chapter structure mismatch" unless actual_headings == expected_headings
  abort "Recovery image count mismatch" unless actual_images.length == expected_image_count
  last_image_id = actual_images.last&.attributes&.[]("id").to_s
  if expected_image_count.positive?
    last_image_top = actual_images.last
    last_image_top = last_image_top.parent while last_image_top.parent != recovery_container
    abort "Recovery batch is not the exact document suffix" unless last_image_id == new_anchor_id && tail_blocks.last == last_image_top
  else
    abort "Recovery batch is not the exact document suffix" unless tail_blocks.last&.attributes&.[]("id").to_s == new_anchor_id
  end
end

state["ignored_transcript_records"] += Array(batch["ignored_transcripts"])
state["unavailable_image_records"] = (state["unavailable_image_records"] + Array(batch["unavailable_images"])).uniq { |item| item["message_id"] }
index_additions["ignored_transcript_ids"].concat(ignored_ids)
index_additions["processed_transcript_ids"].concat(ignored_ids)
state["document"]["revision"] = revision
state["document"]["append_anchor_block_id"] = new_anchor_id
state["current_chapter"] = chapter_cursor unless chapter_cursor.empty?
opened_chapters.each do |chapter|
  state["chapter_history"] << chapter unless state["chapter_history"].any? { |item| item["title"] == chapter["title"] }
end
state["last_course_time_ms"] = [state["last_course_time_ms"].to_i, course_values.max.to_i].max unless course_values.empty?
apply_poll_cursors(state, batch)
state["last_poll_completed_at"] = Time.now.iso8601
state["last_batch_completed_at"] = Time.now.iso8601
state["final_incremental_completed_at"] = Time.now.iso8601 if state["status"] == "finalizing"
persist_state(options[:session], state)
index_additions.each { |field, values| session_index.append(field, values) }
session_index.configure_state!
persist_state(options[:session], state)

cloud_writes = options[:recover_existing] ? 0 : 1
puts "batch_complete added=#{entries.length} image_entries=#{entries.sum { |entry| entry_images(entry).length }} text_entries=#{entries.count { |entry| entry_kind(entry) == 'text' }} revision=#{revision} verified_new_images=#{verified_new_images} cloud_writes=#{cloud_writes} cloud_readbacks=1"
