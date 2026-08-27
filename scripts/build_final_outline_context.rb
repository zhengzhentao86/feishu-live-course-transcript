#!/usr/bin/env ruby

require "json"
require "optparse"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: build_final_outline_context.rb --session state.json --output context.json"
  parser.on("--session FILE") { |value| options[:session] = File.expand_path(value) }
  parser.on("--output FILE") { |value| options[:output] = File.expand_path(value) }
end.parse!
%i[session output].each { |key| abort "Missing --#{key}" if options[key].to_s.empty? }

state = JSON.parse(File.read(options[:session]))
groups = Array(state["content_groups"])
abort "Session has no canonical content_groups; run migrate_session_v5.rb first" if groups.empty?

ordered = groups.sort_by { |group| [group["course_time_ms"].to_i, group["group_id"].to_s] }
context = {
  "task" => "只为课程成品划分主题章节，不改写正文。按课程时间顺序把每个 group_id 恰好分配一次。",
  "course_title" => state["course_title"],
  "teacher" => state["teacher"],
  "rules" => [
    "输出 4—12 个学员可读的主题章节；短课可少于4个",
    "标题使用“主题｜具体内容”形式，不出现补全、回填、第一段、第二段、系统修复等处理痕迹",
    "chapter 顺序和每章 group_ids 都必须保持课程时间顺序",
    "每个 group_id 恰好出现一次，不删除、不重复、不改正文"
  ],
  "output_schema" => {
    "chapters" => [{ "title" => "开场｜课程目标与学习地图", "group_ids" => ["group-id"] }]
  },
  "groups" => ordered.map do |group|
    slide_titles = Array(group["image_message_ids"]).map do |message_id|
      Array(state["accepted_slides"]).find { |slide| slide["message_id"] == message_id }&.dig("slide_title")
    end.compact
    {
      "group_id" => group["group_id"],
      "course_time" => group["course_time"],
      "speaker" => group["speaker"],
      "slide_titles" => slide_titles,
      "text_preview" => Array(group["paragraphs"]).join[0, 320]
    }
  end
}

File.write(options[:output], JSON.pretty_generate(context) + "\n")
puts JSON.generate({ "ok" => true, "output" => options[:output], "groups" => ordered.length })
