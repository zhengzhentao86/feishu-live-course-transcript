# frozen_string_literal: true

require "fileutils"
require "json"
require "set"

class SessionIndex
  FIELDS = %w[
    processed_message_ids
    processed_image_keys
    processed_transcript_ids
    ignored_transcript_ids
    processed_segment_ids
  ].freeze

  def initialize(session_path, state)
    @session_path = File.expand_path(session_path)
    @session_dir = File.dirname(@session_path)
    @state = state
    @sets = {}
  end

  def values(field)
    validate_field(field)
    @sets[field] ||= begin
      values = Array(@state[field]).map(&:to_s).reject(&:empty?)
      values.concat(derived_values(field))
      index_path = absolute_path(field)
      values.concat(File.readlines(index_path, chomp: true)) if File.file?(index_path)
      Set.new(values.reject(&:empty?))
    end
  end

  def include?(field, value)
    values(field).include?(value.to_s)
  end

  def count(field)
    values(field).length
  end

  def append(field, additions)
    validate_field(field)
    fresh = Array(additions).map(&:to_s).reject(&:empty?).uniq.reject { |value| values(field).include?(value) }
    return 0 if fresh.empty?

    path = absolute_path(field)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "a") { |file| fresh.each { |value| file.puts(value) } }
    fresh.each { |value| values(field).add(value) }
    @state["index_counts"] ||= {}
    @state["index_counts"][field] = values(field).length
    fresh.length
  end

  def configure_state!
    @state["indexes"] ||= {}
    FIELDS.each do |field|
      @state["indexes"][field] ||= File.join("indexes", "#{field}.txt")
      @state["index_counts"] ||= {}
      @state["index_counts"][field] = count(field)
    end
  end

  def migrate!
    backup = @session_path + ".v3-backup.json"
    File.write(backup, JSON.pretty_generate(@state) + "\n") unless File.exist?(backup)
    configure_state!
    FIELDS.each do |field|
      existing = values(field).to_a
      path = absolute_path(field)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, existing.join("\n") + (existing.empty? ? "" : "\n"))
      @state[field] = []
      @state["index_counts"][field] = existing.length
      @sets[field] = Set.new(existing)
    end
    backup
  end

  def compact_counts
    FIELDS.each_with_object({}) { |field, memo| memo[field] = count(field) }
  end

  private

  def validate_field(field)
    raise ArgumentError, "Unsupported index field: #{field}" unless FIELDS.include?(field)
  end

  def absolute_path(field)
    relative = @state.dig("indexes", field) || File.join("indexes", "#{field}.txt")
    File.expand_path(relative, @session_dir)
  end

  def derived_values(field)
    slides = Array(@state["accepted_slides"])
    blocks = Array(@state["transcript_blocks"])
    groups = Array(@state["content_groups"])
    values = case field
             when "processed_message_ids"
               slides.map { |item| item["message_id"] }
             when "processed_image_keys"
               slides.map { |item| item["image_key"] }
             when "processed_transcript_ids"
               (groups.empty? ? (slides + blocks) : groups).flat_map { |item| Array(item["transcript_ids"]) } +
                 Array(@state["ignored_transcript_records"]).flat_map { |item| Array(item["transcript_ids"]) }
             when "ignored_transcript_ids"
               Array(@state["ignored_transcript_records"]).flat_map { |item| Array(item["transcript_ids"]) }
             when "processed_segment_ids"
               groups.empty? ? blocks.map { |item| item["segment_id"] } : groups.map { |item| item["group_id"] }
             else
               []
             end
    values.map(&:to_s).reject(&:empty?)
  end
end
