#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "time"
require "tmpdir"

ROOT = Pathname.new(__dir__).join("..").expand_path
PUBLIC_PATHS = %w[SKILL.md README.md LICENSE SECURITY.md .gitignore assets references scripts].freeze

def run_git(*arguments, allow_failure: false)
  stdout, stderr, status = Open3.capture3("git", *arguments, chdir: ROOT.to_s)
  return [stdout, stderr, status] if status.success? || allow_failure

  detail = stderr.lines.last.to_s.strip
  raise "git #{arguments.first} 失败#{detail.empty? ? '' : "：#{detail}"}"
end

def run_safety!
  stdout, stderr, status = Open3.capture3(
    "/usr/bin/ruby",
    ROOT.join("scripts/check_publication_safety.rb").to_s,
    "--staged",
    chdir: ROOT.to_s
  )
  return if status.success?

  detail = (stderr + stdout).lines.last(12).join.strip
  raise "发布安全检查未通过\n#{detail}"
end

abort("当前目录还不是 Git 仓库") unless ROOT.join(".git").directory?

lock_path = File.join(Dir.tmpdir, "feishu-live-course-transcript-github-sync.lock")
FileUtils.mkdir_p(File.dirname(lock_path))

File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock_file|
  exit 0 unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)

  _, _, rebase_status = run_git("rev-parse", "-q", "--verify", "REBASE_HEAD", allow_failure: true)
  raise "仓库正在 rebase，自动同步已停止" if rebase_status.success?

  run_git("add", "--all", "--", *PUBLIC_PATHS)
  staged, = run_git("diff", "--cached", "--name-only")

  unless staged.empty?
    run_safety!
    message = "chore: auto-sync #{Time.now.iso8601}"
    run_git("commit", "-m", message)
  end

  _, pull_error, pull_status = run_git("pull", "--rebase", "origin", "main", allow_failure: true)
  unless pull_status.success?
    run_git("rebase", "--abort", allow_failure: true)
    raise "远端更新无法自动合并，已停止且未强制覆盖：#{pull_error.lines.last.to_s.strip}"
  end

  run_git("push", "origin", "main")
  puts "github_sync=ok time=#{Time.now.iso8601}"
end
