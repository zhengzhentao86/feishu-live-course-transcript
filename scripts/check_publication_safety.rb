#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"

ROOT = Pathname.new(__dir__).join("..").expand_path
ALLOWED_ROOT_FILES = %w[.gitignore LICENSE README.md SECURITY.md SKILL.md].freeze
ALLOWED_PREFIXES = %w[assets/ references/ scripts/].freeze

RULES = {
  "macOS 用户绝对路径" => Regexp.new("/" + "Users/[^/\\s]+/"),
  "Linux 用户绝对路径" => Regexp.new("/" + "home/[^/\\s]+/"),
  "飞书或 Lark 链接" => %r{https?://[^\s)\]>]*(?:feishu\.cn|larksuite\.com|larkoffice\.com)[^\s)\]>]*}i,
  "GitHub 访问令牌" => /(?:ghp|github_pat)_[A-Za-z0-9_]{20,}/,
  "常见云服务访问密钥" => /AKIA[0-9A-Z]{16}/,
  "疑似私钥" => /-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----/,
  "疑似通用密钥赋值" => /(?:secret|password|access[_-]?token|api[_-]?key)\s*[:=]\s*["'][^"']{12,}["']/i
}.freeze

def git_paths(mode)
  command = if mode == "--staged"
              ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"]
            else
              ["git", "ls-files", "-z"]
            end
  stdout, stderr, status = Open3.capture3(*command, chdir: ROOT.to_s)
  abort("无法读取 Git 文件清单：#{stderr.lines.last.to_s.strip}") unless status.success?
  stdout.split("\0").reject(&:empty?)
end

mode = ARGV.first || "--tracked"
abort("用法：ruby scripts/check_publication_safety.rb [--staged|--tracked]") unless %w[--staged --tracked].include?(mode)

violations = []
git_paths(mode).each do |relative_path|
  allowed = ALLOWED_ROOT_FILES.include?(relative_path) || ALLOWED_PREFIXES.any? { |prefix| relative_path.start_with?(prefix) }
  unless allowed
    violations << [relative_path, 0, "不在公共发布白名单"]
    next
  end

  file_path = ROOT.join(relative_path)
  next unless file_path.file?
  if file_path.size > 2 * 1024 * 1024
    violations << [relative_path, 0, "单文件超过 2 MiB"]
    next
  end

  content = file_path.binread.force_encoding(Encoding::UTF_8)
  next unless content.valid_encoding?
  content.each_line.with_index(1) do |line, line_number|
    RULES.each do |rule_name, pattern|
      violations << [relative_path, line_number, rule_name] if line.match?(pattern)
    end
  end
end

if violations.empty?
  puts "publication_safety=passed files=#{git_paths(mode).length}"
  exit 0
end

warn "publication_safety=blocked violations=#{violations.length}"
violations.each { |relative_path, line_number, rule_name| warn "#{relative_path}:#{line_number}: #{rule_name}" }
exit 1
