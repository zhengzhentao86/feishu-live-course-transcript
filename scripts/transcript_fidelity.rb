# frozen_string_literal: true

module TranscriptFidelity
  MAX_PARAGRAPH_LENGTH = 230
  MIN_RETENTION_RATIO = 0.80
  MIN_GROUNDING_RATIO = 0.75
  MAX_DENSE_SPAN_SECONDS = 180
  DENSE_SOURCE_LENGTH = 160

  module_function

  def paragraphs(entry)
    values = entry["paragraphs"]
    values = [entry["text"]] unless values.is_a?(Array)
    values.map(&:to_s).map(&:strip).reject(&:empty?)
  end

  def plain_output(entry)
    paragraphs(entry).join.gsub(/\[\[|\]\]/, "")
  end

  def normalize(text)
    text.to_s.gsub(/\[\[|\]\]/, "").downcase.scan(/[\p{Han}a-z0-9]/u).join
  end

  def seconds(value)
    parts = value.to_s.split(":").map(&:to_i)
    return nil unless parts.length == 3

    (parts[0] * 3600) + (parts[1] * 60) + parts[2]
  end

  def lcs_length(left, right)
    return 0 if left.empty? || right.empty?

    previous = Array.new(right.length + 1, 0)
    left.each_char do |left_char|
      current = Array.new(right.length + 1, 0)
      right.each_char.with_index(1) do |right_char, index|
        current[index] = if left_char == right_char
                           previous[index - 1] + 1
                         else
                           [previous[index], current[index - 1]].max
                         end
      end
      previous = current
    end
    previous.last
  end

  def report(entry, require_source: true)
    label = entry["segment_id"] || entry["message_id"] || entry["position"] || "unknown"
    output_paragraphs = paragraphs(entry)
    source = normalize(entry["source_text"])
    output = normalize(output_paragraphs.join)
    failures = []

    failures << "正文为空" if output.empty?
    output_paragraphs.each_with_index do |paragraph, index|
      length = paragraph.gsub(/\[\[|\]\]/, "").length
      failures << "第 #{index + 1} 段 #{length} 字，超过 #{MAX_PARAGRAPH_LENGTH} 字" if length > MAX_PARAGRAPH_LENGTH
    end

    if source.empty?
      failures << "缺少 source_text，无法确认没有被压成摘要" if require_source
      return {
        "label" => label.to_s,
        "source_length" => 0,
        "output_length" => output.length,
        "retention_ratio" => nil,
        "grounding_ratio" => nil,
        "failures" => failures
      }
    end

    retention_ratio = output.length.fdiv(source.length)
    grounding_ratio = output.empty? ? 0.0 : lcs_length(source, output).fdiv(output.length)
    if retention_ratio < MIN_RETENTION_RATIO
      failures << format("保留比例 %.3f，低于 %.2f；请拆段保留讲解过程，不要改成摘要", retention_ratio, MIN_RETENTION_RATIO)
    end
    if grounding_ratio < MIN_GROUNDING_RATIO
      failures << format("原文顺序匹配比例 %.3f，低于 %.2f；改写幅度过大", grounding_ratio, MIN_GROUNDING_RATIO)
    end

    start_seconds = seconds(entry["meeting_time"])
    end_seconds = seconds(entry["meeting_end_time"])
    if start_seconds && end_seconds && end_seconds > start_seconds
      span = end_seconds - start_seconds
      if span > MAX_DENSE_SPAN_SECONDS && source.length >= DENSE_SOURCE_LENGTH
        failures << "时间跨度 #{span} 秒且课程原文 #{source.length} 字；请拆成多个连续条目"
      end
    end

    {
      "label" => label.to_s,
      "source_length" => source.length,
      "output_length" => output.length,
      "retention_ratio" => retention_ratio.round(3),
      "grounding_ratio" => grounding_ratio.round(3),
      "paragraph_count" => output_paragraphs.length,
      "failures" => failures
    }
  end
end
