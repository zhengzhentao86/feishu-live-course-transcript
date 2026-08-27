#!/usr/bin/env ruby

require "json"
require "optparse"
require_relative "session_index"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: build_model_context.rb --session state.json --manifest manifest.json --output context.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--manifest FILE") { |value| options[:manifest] = File.expand_path(value) }
  parser.on("--output FILE") { |value| options[:output] = File.expand_path(value) }
end.parse!
%i[session manifest output].each { |key| abort "Missing --#{key}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
manifest = JSON.parse(File.read(options[:manifest]))
index = SessionIndex.new(options[:session], state)
history = Array(state["content_groups"])
history = (Array(state["accepted_slides"]) + Array(state["transcript_blocks"])) if history.empty?
previous = history
  .sort_by { |item| item["course_end_time_ms"] || item["transcript_end_ms"].to_i }
  .last(2)
  .flat_map { |item| Array(item["paragraphs"] || item["text"]) }
  .last(2)

context = {
  "task" => "只处理这一批：轻度精修、明确 ASR 错字纠正、图片语义对齐、自然分段和重点标记",
  "revision" => state.dig("document", "revision"),
  "speaker_map" => state["speaker_map"] || {},
  "previous_last_two_paragraphs" => previous,
  "new_transcripts" => manifest["new_transcripts"] || [],
  "new_images" => Array(manifest["new_images"]).map do |image|
    image.slice("message_id", "image_key", "message_position", "create_time", "local_path", "ocr_title", "ocr_text")
  end,
  "output_contract" => {
    "single_image_primary" => "连续多图先依据 OCR 标题、页面正文、发送顺序和转写句意拆分；默认每个 assignment 输出 kind=image + 单个 message_id，并使用互不重复的 transcript_ids",
    "image_group_fallback" => "仅当同页重拍、不可拆总览或同一段共享讲解无法可靠分配时，才输出 kind=image_group、按消息顺序的 message_ids、alignment_mode=shared_explanation 和具体 alignment_reason；正文只写一次并由脚本并排",
    "chapter_title" => "发生明确课程主题切换时，在该批首个对应 assignment 填简短 chapter_title；延续当前主题时留空",
    "text" => "没有适合图片的新增转写仍输出 kind=text"
  },
  "quality_rules" => [
    "只删口水词、立即自我纠正、逐字重复和无关课堂杂项",
    "保留原顺序、案例、数字、条件、转折、原因、推演和结论",
    "每个自然段不超过230字；内容多就拆段，禁止摘要",
    "正文/source_text保留率>=80%，正文原文顺序依据>=75%",
    "优先一段相关讲解配一张图；不能因连续发送就合并，也不能把同一正文复制给多图；确实无法拆分才用带原因的并排 image_group",
    "重点仅用[[...]]标记1-4处，不新增讲师没讲过的内容"
  ],
  "state_summary" => {
    "index_counts" => index.compact_counts,
    "last_message_position" => state["last_message_position"],
    "last_transcript_end_time" => state["last_transcript_end_time"],
    "meeting_ids" => Array(state["meeting_ids"]),
    "current_meeting_id" => state["current_meeting_id"],
    "meeting_label" => manifest.dig("meeting", "label"),
    "course_start" => state["course_start"],
    "current_chapter" => state["current_chapter"],
    "teacher" => state["teacher"]
  }
}

forbidden = %w[processed_message_ids processed_image_keys processed_transcript_ids ignored_transcript_ids processed_segment_ids]
abort "Context leaked processed ID arrays" unless (context.keys & forbidden).empty?
File.write(options[:output], JSON.pretty_generate(context) + "\n")
puts JSON.generate({ "ok" => true, "output" => options[:output], "transcripts" => context["new_transcripts"].length, "images" => context["new_images"].length })
