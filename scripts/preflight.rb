#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"
require "rbconfig"

REQUIRED_SCOPES = %w[
  docs:document.content:read
  docs:document.media:download
  docs:document.media:upload
  docx:document:create
  docx:document:readonly
  docx:document:write_only
  im:chat:read
  im:message.group_msg:get_as_user
  im:resource
  minutes:minutes.basic:read
  minutes:minutes.search:read
  minutes:minutes.transcript:export
  vc:meeting.meetingevent:read
  vc:meeting.search:read
  vc:note:read
].freeze

CLI_ENV = {
  "LARKSUITE_CLI_NO_UPDATE_NOTIFIER" => "1",
  "LARKSUITE_CLI_NO_SKILLS_NOTIFIER" => "1"
}.freeze

options = { install_lark_cli: false, yes: false, offline: false }
OptionParser.new do |parser|
  parser.banner = "Usage: preflight.rb [--install-lark-cli --yes] [--offline]"
  parser.on("--install-lark-cli") { options[:install_lark_cli] = true }
  parser.on("--yes") { options[:yes] = true }
  parser.on("--offline") { options[:offline] = true }
end.parse!

def executable?(file_path)
  File.file?(file_path) && File.executable?(file_path)
end

def find_command(command_name)
  candidates = []
  explicit = ENV["LARK_CLI_BIN"] if command_name == "lark-cli"
  candidates << explicit unless explicit.to_s.empty?
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
    candidates << File.join(directory, command_name) unless directory.empty?
  end
  if command_name == "lark-cli"
    candidates.concat([
      File.join(Dir.home, ".local", "bin", "lark-cli"),
      File.join(Dir.home, ".npm-global", "bin", "lark-cli"),
      "/opt/homebrew/bin/lark-cli",
      "/usr/local/bin/lark-cli"
    ])
  end
  candidates.compact.uniq.find { |candidate| executable?(candidate) }
end

def parse_json(text)
  JSON.parse(text)
rescue JSON::ParserError
  nil
end

def emit(payload, exit_code = 0)
  puts JSON.pretty_generate(payload)
  exit exit_code
end

def base_payload
  {
    "schema_version" => 1,
    "platform" => RUBY_PLATFORM,
    "safe_install_requires_confirmation" => true
  }
end

unless RUBY_PLATFORM.include?("darwin")
  emit(base_payload.merge(
    "ok" => false,
    "action" => "stop",
    "reason" => "当前 Skill 的本地 OCR 与自动任务只支持 macOS。"
  ), 2)
end

lark_cli = find_command("lark-cli")
npm = find_command("npm")
swift = find_command("swift")

if lark_cli.nil? && options[:install_lark_cli]
  unless options[:yes]
    emit(base_payload.merge(
      "ok" => false,
      "action" => "confirm_install",
      "reason" => "安装 lark-cli 会下载 npm 软件包并写入 ~/.local，必须先取得用户明确同意。",
      "install_command" => "ruby scripts/preflight.rb --install-lark-cli --yes"
    ), 3)
  end

  if npm.nil?
    brew = find_command("brew")
    emit(base_payload.merge(
      "ok" => false,
      "action" => "install_node",
      "reason" => "未找到 npm，不能安装 lark-cli。",
      "next_step" => brew ? "征得用户同意后运行 brew install node，再重试预检。" : "请先安装 Node.js（含 npm），再重试预检。"
    ), 4)
  end

  install_prefix = File.join(Dir.home, ".local")
  mirror = "https://registry.npmmirror.com"
  stdout, stderr, cmd_status = Open3.capture3(
    { "NPM_CONFIG_REGISTRY" => mirror },
    npm, "install", "-g", "@larksuite/cli", "--prefix", install_prefix,
    "--registry", mirror
  )
  unless cmd_status.success?
    emit(base_payload.merge(
      "ok" => false,
      "action" => "install_failed",
      "reason" => "lark-cli 安装失败。",
      "detail" => (stderr.lines.last(5) + stdout.lines.last(3)).join.strip
    ), 5)
  end
  lark_cli = find_command("lark-cli")
end

if lark_cli.nil?
  emit(base_payload.merge(
    "ok" => false,
    "action" => "install_lark_cli",
    "reason" => "未找到 lark-cli。",
    "package" => "@larksuite/cli",
    "install_preview" => "npm install -g @larksuite/cli --prefix ~/.local --registry https://registry.npmmirror.com",
    "next_step" => "先向用户说明会下载 npm 软件包并写入 ~/.local；用户明确同意后运行 ruby scripts/preflight.rb --install-lark-cli --yes。"
  ), 6)
end

if swift.nil?
  emit(base_payload.merge(
    "ok" => false,
    "action" => "install_swift",
    "reason" => "未找到 Swift，无法运行本地 Vision OCR。",
    "lark_cli_path" => lark_cli,
    "next_step" => "请先安装 Xcode Command Line Tools，再重新运行预检。"
  ), 7)
end

auth_args = [lark_cli, "auth", "status", "--json"]
auth_args << "--verify" unless options[:offline]
stdout, stderr, cmd_status = Open3.capture3(CLI_ENV, *auth_args)
auth_payload = parse_json(stdout.strip) || parse_json(stderr.strip)

unless cmd_status.success? && auth_payload.is_a?(Hash)
  combined = [stdout, stderr].join("\n")
  action = combined.match?(/config|app.?id|not initialized/i) ? "configure_lark_cli" : "login_lark_cli"
  next_step = if action == "configure_lark_cli"
                "运行 lark-cli config init --new，并按输出完成应用配置。"
              else
                "运行 lark-cli auth login --scope \"#{REQUIRED_SCOPES.join(' ')}\" --no-wait --json，向用户展示原始授权链接和二维码。"
              end
  emit(base_payload.merge(
    "ok" => false,
    "action" => action,
    "reason" => "无法确认 lark-cli 用户登录状态。",
    "lark_cli_path" => lark_cli,
    "next_step" => next_step
  ), 8)
end

user = auth_payload.dig("identities", "user") || {}
unless user["status"] == "ready" && user["available"] != false && (options[:offline] || auth_payload["verified"] == true)
  emit(base_payload.merge(
    "ok" => false,
    "action" => "login_lark_cli",
    "reason" => "lark-cli 已安装，但用户身份未登录或 token 无效。",
    "lark_cli_path" => lark_cli,
    "requested_scopes" => REQUIRED_SCOPES,
    "next_step" => "运行 lark-cli auth login --scope \"#{REQUIRED_SCOPES.join(' ')}\" --no-wait --json，向用户展示原始授权链接和二维码；用户确认后由 Agent 完成 device-code 交换。"
  ), 9)
end

granted_scopes = user.fetch("scope", "").split(/\s+/).reject(&:empty?)
missing_scopes = REQUIRED_SCOPES - granted_scopes
unless missing_scopes.empty?
  emit(base_payload.merge(
    "ok" => false,
    "action" => "authorize_scopes",
    "reason" => "lark-cli 已登录，但课程整理所需权限不完整。",
    "lark_cli_path" => lark_cli,
    "user_name" => user["userName"],
    "missing_scopes" => missing_scopes,
    "next_step" => "运行 lark-cli auth login --scope \"#{missing_scopes.join(' ')}\" --no-wait --json，向用户展示原始授权链接和二维码。"
  ), 10)
end

emit(base_payload.merge(
  "ok" => true,
  "action" => "ready",
  "reason" => "环境、lark-cli 用户登录和所需权限均已就绪。",
  "lark_cli_path" => lark_cli,
  "lark_cli_env" => { "LARK_CLI_BIN" => lark_cli },
  "user_name" => user["userName"],
  "ruby_path" => RbConfig.ruby,
  "swift_path" => swift,
  "checked_online" => !options[:offline]
))
