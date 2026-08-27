#!/usr/bin/env ruby

require "json"
require "optparse"

options = { supports_model_override: true }
OptionParser.new do |parser|
  parser.banner = "Usage: route_model.rb --manifest manifest.json [--signals signals.json] [--no-model-override]"
  parser.on("--manifest FILE") { |value| options[:manifest] = File.expand_path(value) }
  parser.on("--signals FILE") { |value| options[:signals] = File.expand_path(value) }
  parser.on("--no-model-override") { options[:supports_model_override] = false }
end.parse!
abort "Missing --manifest" if options[:manifest].to_s.empty?

manifest = JSON.parse(File.read(options[:manifest]))
signals = options[:signals] ? JSON.parse(File.read(options[:signals])) : {}
route = (manifest["route"] || {}).merge(signals)

required = %w[
  new_image_count new_transcript_chars transcript_duration_seconds
  ambiguous_alignment_count comments_count meeting_status
  formal_minutes_available revision_drift structure_error
  previous_validation_failed retry_count
]
missing = required.reject { |key| route.key?(key) }
abort "Route input missing: #{missing.join(', ')}" unless missing.empty?

image_count = route["new_image_count"].to_i
transcript_chars = route["new_transcript_chars"].to_i
duration = route["transcript_duration_seconds"].to_i
ambiguities = route["ambiguous_alignment_count"].to_i
comments = route["comments_count"].to_i
speaker_count = route.fetch("speaker_count", 1).to_i
meeting_switch_count = route.fetch("meeting_switch_count", 0).to_i

action = "run"
model = "gpt-5.6-terra"
effort = "medium"
reason = "普通图文对齐或 ASR 纠错"

if route["revision_drift"] == true || route["structure_error"] == true
  action = "stop"
  model = nil
  effort = nil
  reason = route["revision_drift"] == true ? "revision 漂移，禁止猜测或写入" : "文档结构异常，禁止猜测或写入"
elsif route["historical_backfill_required"] == true
  action = "rebuild"
  model = nil
  effort = nil
  reason = "检测到早于文档尾部的历史缺口，禁止继续尾部追加；进入课程级重建"
elsif route["speaker_mapping_missing"] == true
  action = "stop"
  model = nil
  effort = nil
  reason = "讲师映射未确认，禁止按设备账号名写入"
elsif image_count.zero? && transcript_chars.zero?
  action = "exit"
  model = nil
  effort = nil
  reason = "没有新增图片和新增转写"
elsif image_count.positive? && transcript_chars.zero?
  action = "wait"
  model = nil
  effort = nil
  reason = "新图片暂时没有对应新增转写，保留游标等待下一轮上下文"
elsif route["previous_validation_failed"] == true && route["retry_count"].to_i == 1 && route["failure_class"] == "complex_semantic"
  model = "gpt-5.6-sol"
  effort = "medium"
  reason = "Terra 的最小语义片段已失败一次，仅升级该片段"
elsif image_count > 8 || comments.positive? || speaker_count > 1 || meeting_switch_count.positive? || ambiguities >= 2 ||
      (route["meeting_status"] == "ended" && route["formal_minutes_available"] == true)
  model = "gpt-5.6-terra"
  effort = "high"
  reason = "正式收尾、评论修订、讲师或会议切换、或多处对齐歧义"
elsif image_count.zero? && duration <= 600 && ambiguities.zero?
  model = "gpt-5.6-terra"
  effort = "low"
  reason = "十分钟内纯文本增量且无语义歧义"
end

result = {
  "action" => action,
  "model" => model,
  "reasoning_effort" => effort,
  "reason" => reason,
  "max_input_tokens" => 12_000,
  "max_output_tokens" => 3_000
}

if action == "run" && !options[:supports_model_override]
  result["recommended_model"] = model
  result["recommended_effort"] = effort
  result["model"] = "gpt-5.6-terra"
  result["reasoning_effort"] = "medium"
  result["reason"] = "运行环境不支持动态覆盖；回退 Terra medium；建议档位为 #{result['recommended_model']} #{result['recommended_effort']}"
end

puts JSON.pretty_generate(result)
