#!/usr/bin/env ruby

require "cgi"
require "json"
require "optparse"
require "pathname"
require "time"
require_relative "transcript_fidelity"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: render_final_document.rb --session state.json --outline outline.json --output final.xml"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--outline FILE") { |value| options[:outline] = File.expand_path(value) }
  parser.on("--output FILE") { |value| options[:output] = File.expand_path(value) }
end.parse!
%i[session outline output].each { |key| abort "Missing --#{key}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
outline = JSON.parse(File.read(options[:outline]))
session_dir = File.dirname(options[:session])
groups = Array(state["content_groups"])
abort "Session has no canonical content_groups; run migrate_session_v5.rb first" if groups.empty?
group_map = groups.each_with_object({}) { |group, memo| memo[group.fetch("group_id")] = group }
ordered_group_ids = groups.sort_by { |group| [group["course_time_ms"].to_i, group["group_id"].to_s] }.map { |group| group["group_id"] }

chapters = Array(outline["chapters"])
abort "Final outline must contain chapters" if chapters.empty?
abort "Final outline has too many chapters; maximum is 12" if chapters.length > 12
abort "A course with at least 10 content groups needs at least 2 semantic chapters" if groups.length >= 10 && chapters.length < 2
assigned_ids = chapters.flat_map { |chapter| Array(chapter["group_ids"]) }
abort "Final outline has duplicate group_ids" unless assigned_ids.uniq.length == assigned_ids.length
abort "Final outline must include every group exactly once" unless assigned_ids.sort == ordered_group_ids.sort
abort "Final outline changed course order" unless assigned_ids == ordered_group_ids

banned_title = /补全|回填|第[一二三四五六七八九十\d]+段|系统修复|图片补/
chapters.each do |chapter|
  title = chapter["title"].to_s.strip
  abort "Chapter title is empty" if title.empty?
  abort "Chapter title exposes repair history: #{title}" if title.match?(banned_title)
end

transcript_ids = groups.flat_map { |group| Array(group["transcript_ids"]) }.reject(&:empty?)
abort "Canonical groups reuse transcript IDs" unless transcript_ids.uniq.length == transcript_ids.length
groups.each do |group|
  report = TranscriptFidelity.report(group, require_source: true)
  abort "Final fidelity failed at #{report['label']}: #{report['failures'].join('; ')}" unless report["failures"].empty?
end

slides = Array(state["accepted_slides"])
slide_by_message = slides.each_with_object({}) { |slide, memo| memo[slide["message_id"]] = slide }
used_messages = groups.flat_map { |group| Array(group["image_message_ids"]) }
abort "Canonical groups reuse image messages" unless used_messages.uniq.length == used_messages.length
abort "Canonical groups do not cover every accepted image" unless used_messages.sort == slides.map { |slide| slide["message_id"] }.sort

def rich_text(text)
  text.to_s.split(/(\[\[[^\]]+\]\])/).map do |part|
    if part.start_with?("[[") && part.end_with?("]]" )
      %Q(<b><span text-color="rgb(36,91,219)">#{CGI.escapeHTML(part[2...-2])}</span></b>)
    else
      CGI.escapeHTML(part)
    end
  end.join
end

def group_stamp(group)
  start_time = group["course_time"].to_s
  end_time = group["course_end_time"].to_s
  range = end_time.empty? || end_time == start_time ? start_time : "#{start_time}–#{end_time}"
  "#{group['speaker']} · #{range}"
end

def resolve_slide_file(slide, session_dir)
  explicit = slide["local_path"].to_s
  return File.expand_path(explicit, session_dir) if !explicit.empty? && File.file?(File.expand_path(explicit, session_dir))

  image_name = slide["image_name"].to_s
  candidates = Dir.glob(File.join(session_dir, "**", "*"), File::FNM_DOTMATCH).select { |file_path| File.file?(file_path) }
  candidates.find { |file_path| image_name.end_with?(File.basename(file_path)) }
end

unavailable = Array(state["unavailable_image_records"])
lines = [
  "<h1>阅读说明</h1>",
  "<ul>",
  "<li>逐字稿采用忠实精修：只删口水词、立即自我纠正、逐字重复和无关课堂杂项，保留案例、数字、条件、因果、问答与原讲解顺序，不压缩成摘要。</li>",
  "<li>时间使用整门课程的连续相对时间；课程发生续场换会时不重新从 00:00:00 开始。</li>",
  "<li>同一段讲解对应多张连续 PPT 时，正文只出现一次，图片按群内发送顺序紧跟其后。</li>",
  "<li>蓝色加粗用于标记关键术语、方法、结论与步骤；没有新 PPT 的讲解继续以纯文本时间条目记录。</li>"
]
unless unavailable.empty?
  positions = unavailable.map { |item| item["message_position"] }.compact.join("、")
  lines << "<li>另有 #{unavailable.length} 条群图片消息已被删除，无法恢复；已保留缺失记录#{positions.empty? ? '' : "（群消息位置 #{CGI.escapeHTML(positions)}）"}。</li>"
end
lines << "</ul>"

page_number = 0
chapters.each do |chapter|
  lines << "<h1>#{CGI.escapeHTML(chapter.fetch('title'))}</h1>"
  Array(chapter["group_ids"]).each do |group_id|
    group = group_map.fetch(group_id)
    lines << %Q(<p><b>#{CGI.escapeHTML(group_stamp(group))}</b></p>)
    Array(group["paragraphs"]).each { |paragraph| lines << %Q(<p>#{rich_text(paragraph)}</p>) }
    Array(group["image_message_ids"]).each do |message_id|
      slide = slide_by_message.fetch(message_id)
      file_path = resolve_slide_file(slide, session_dir)
      abort "Local image missing for #{message_id}" unless file_path && File.size(file_path).positive?
      relative = Pathname.new(file_path).relative_path_from(Pathname.new(session_dir)).to_s
      page_number += 1
      title = slide["slide_title"].to_s.empty? ? "标题待识别" : slide["slide_title"].to_s
      caption = format("正式 PPT 第 %03d 页｜课程约 %s｜%s", page_number, group["course_time"], title)
      name = slide["image_name"].to_s.empty? ? format("%04d-%s-%s", slide["position"].to_i, message_id, File.basename(file_path)) : slide["image_name"]
      lines << %Q(<img path="@./#{CGI.escapeHTML(relative)}" width="780" name="#{CGI.escapeHTML(name)}" caption="#{CGI.escapeHTML(caption)}"/>)
    end
  end
end

File.write(options[:output], lines.join("\n") + "\n")
puts JSON.pretty_generate({
  "ok" => true,
  "output" => options[:output],
  "chapters" => chapters.length,
  "content_groups" => groups.length,
  "images" => page_number,
  "unavailable_images" => unavailable.length
})
