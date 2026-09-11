# 课中整理：会议转写与群内照片

仅 `mode=live` 读取。共同质量基线见入口；最终格式见 `style-standard.md`。

## 课中两级预检

安装后首次调用、换电脑或 lark-cli 报错时，先运行环境预检 `ruby scripts/preflight.rb`。正常热路径不要重复环境预检。

- `action=ready`：沿用输出的 `LARK_CLI_BIN`，再初始化课程。
- `action=install_lark_cli`：告诉用户将通过国内 npm 镜像下载 `@larksuite/cli` 并写入 `~/.local`；只有用户明确同意后才能运行 `ruby scripts/preflight.rb --install-lark-cli --yes`。禁止静默安装、使用 sudo 或改写系统目录。
- `action=install_node|install_swift`：说明缺失依赖并停止；安装 Node.js 或 Xcode Command Line Tools 前另行取得同意。
- `action=configure_lark_cli`：运行 `lark-cli config init --new`，严格按 lark-cli 输出展示原始配置链接和二维码。
- `action=login_lark_cli|authorize_scopes`：按输出的最小 scope 发起 `--no-wait --json` 授权，先展示原始链接和二维码并结束当前轮；用户回复已授权后，由 Agent 执行 device-code 交换。
- 安装、配置、登录或授权完成后重新运行预检；未得到 `ready` 不创建课程文档、不读取群消息。

每堂新课在创建文档和自动任务前，运行一次课程预检：

```bash
ruby scripts/course_preflight.rb --chat-id <chat_id> --course-start <ISO8601> --event-identity user
```

- 脚本会自动发现当前登录用户唯一的进行中会议；有多个候选才要求选择。必须同时确认群可读、会议事件可读并取得至少一个实时字幕样本；未得到 `action=ready` 不建文档、不启动心跳。
- 用户明确要求智能体独立入会时，可用 `--meeting-number <9位会议号> --join-bot --yes`。这会让应用机器人真实入会并保持在会中，必须沿用返回的 `meeting_id` 和 `event_identity=bot`。
- `enable_independent_agent_join`：提示用户开启租户的智能体独立入会能力；保留现场，不把“开启 AI 纪要”误说成唯一条件。
- `wait_for_live_transcript_sample`：等讲师说话后重试；不得把“会议可见”当成“实时字幕可采”。
- `late_start_requires_minutes_backfill`：课程已开始较久且无法证明字幕从开头覆盖；进入课程级重建，不创建一个从当前时刻假装完整的实时稿。

## 初始化与迁移

运行 `scripts/init_session.rb` 创建工作文档和 v5 会话。v5 同时记录 `course_start`、`meeting_sessions`、统一课程时间、`content_groups`、主题章节和最终文档。课程数据只能放在会话工作目录，不能放进 Skill 安装目录。

旧会话先在课前运行：

```bash
ruby scripts/migrate_session_v3.rb --session <state.json>
ruby scripts/migrate_session_v4.rb --session <state.json>
ruby scripts/migrate_session_v5.rb --session <state.json>
```

v4 把长 processed ID 数组迁移到 `indexes/*.txt`；v5 建立课程级 canonical groups、续会清单并重建物理索引。迁移若发现时间倒退或 transcript ID 重复，设置 `requires_document_rebuild=true`，不得继续尾部追加。

## 普通热路径：每 2 分钟检查，2–6 分钟一个批次

1. 运行 `scripts/collect_incremental.rb --session <state> --output-dir <新run目录>`。脚本并行读取：
   - 群消息：查询起点取 `min(last_message_scan_end, last_message_time)`（缺失时回退到 `meeting_start`），到当前时间使用完整 ISO 8601 窄窗口，`--order asc --page-all --no-reactions`；存在位置游标时以 `message_position > last_message_position` 和本地索引为权威过滤条件，禁止再用扫描时间丢弃位置更新的消息。
   - 会中转写：优先事件 page token，否则只从 `last_transcript_end_time` 到当前时间；禁止从会议开头重拉。
2. 第一轮从 `course_start` 建立课程群图片全量基线；摄影者为空时接收群内全部图片发送者。后续只下载/OCR 本轮新图；已删除图片写入 `unavailable_image_records`。积压超过 6 分钟时只取最早 6 分钟，下一轮续写。被本轮字幕窗口截断的较晚图片必须保留为消息积压：只把 `last_message_position/last_message_time` 推进到实际入批的最后一条消息；`last_message_scan_end` 保持单调，但不得作为排除位置更新消息的依据。
3. 先运行 `scripts/route_model.rb --manifest <manifest>`：`exit` 用 `commit_empty_poll.rb` 提交安全游标；`wait` 表示新图还没有对应字幕，不推进游标、下轮重试；`stop` 保留现场；`rebuild` 进入课程级重建；只有 `run` 才继续模型和云写入。
4. 运行 `scripts/build_model_context.rb`。模型只允许看到：本批新转写、新图 OCR 标题和发送时间、上一批最后两段、讲师映射、当前 revision、简版质量规则。
5. 模型只负责轻度精修、明确 ASR 错字、图片与讲解语义对齐、自然分段、主题切换和重点标记。多张连续图片默认分别输出 `kind=image + message_id`，把互不重复的转写句子分给语义最匹配的页面；不要为了凑“一图一段”复制正文。只有语义确实无法可靠拆分时才输出 `kind=image_group + message_ids + alignment_mode=shared_explanation + alignment_reason`，脚本会将其按最多四列并排。禁止把完整群历史、完整文档 XML、processed ID 数组和旧日志放入上下文。
6. 运行 `scripts/build_batch.rb`，由脚本确定性补齐 source_text、时间换算、segment key、图片资源、覆盖检查和 batch JSON。随后运行 `scripts/validate_fidelity.rb`。
7. 一个 2–6 分钟批次只运行一次 `scripts/append_batch.rb`：一次 docs update，一次尾部 range fetch。脚本使用连续课程时间；新条目早于已验证尾部时返回 `historical_backfill_requires_rebuild`，严禁追加“补全”章节。

课中禁止全文/整章 fetch、历史图片检查、`media-preview`、正式妙记、逐条写入、逐条回读和 `validate_session.rb`。

## 确定性模型路由

`scripts/route_model.rb` 是唯一模型选择入口：

- 零增量：`exit`，不用模型。
- 新图片暂时没有新增字幕：`wait`，不推进游标，等下一轮上下文。
- 发现历史缺口或迁移后的时间/索引冲突：`rebuild`，不写工作文档。
- revision 漂移或结构异常：`stop`，不用模型。
- 十分钟内纯文本且无歧义：`gpt-5.6-terra + low`。
- 1—8 张新图、普通图文对齐或 ASR 纠错：`gpt-5.6-terra + medium`。
- 正式妙记收尾、用户评论、多讲师/多会议切换、至少两处歧义：`gpt-5.6-terra + high`。
- 只有 Terra 的最小局部片段因复杂语义验证失败一次，才能把该片段升级为 `gpt-5.6-sol + medium`；权限、revision、网络、资源或脚本错误不得升级。
- 禁止 pro、xhigh、max；禁止把整堂课、完整群历史或完整云文档交给 Sol。

运行环境支持模型覆盖时，创建短生命周期 worker，必须 `fork_turns="none"`，只传 compact context、state 路径、增量素材路径和本批验收标准。环境不支持时，按路由器输出的 recommended 档位提示，但实际统一回退 Terra medium，不得声称切换成功。

## 整门课结束：转入共同成品流程

单个会议结束不等于整门课结束。先用原身份检查 active meeting 和群内新的续场会议消息；有续场时记录已结束的场次，再切换 meeting ID、开始时间和讲师，继续热路径。

确认整门课结束后，把状态设为 `finalizing`，完成最后增量批次。整堂课的正式妙记采集一次完整快照，用于校正错字、专名、说话人、缺失尾段和历史缺口；不要在工作文档尾部追加“补全/回填”。使用 `mark_minutes_corrected.rb` 记录来源。存在历史缺口时，先基于全部会议转写和完整群图清单重建 canonical groups。

然后读取 [共同成品流程](finalization.md)，生成用户认可的主题式连续阅读版本。保留实时工作稿。课中数据仍用 v5 状态，不伪造缺失预检、字幕或验收记录。

## 故障边界

- lark-cli 不可用、未登录、权限、网络或资源失败：说明并停止；不得换浏览器或升级模型。
- 写入超时：按本批唯一时间戳、图片名和 revision 局部回读；确认未落地才重试，不能重写整批。
- 写入结果不确定但局部回读证明本批已完整落地时，只允许使用 `append_batch.rb --recover-existing` 提交状态，不得再次上传。恢复不能假设 revision 只增加 1：含图片的单次更新可能触发多次内部 revision；必须要求云端 revision 大于本地记录、本批时间戳/正文/章节/图片数量与顺序精确匹配、并且本批恰好位于旧尾锚点之后。图片名称同时接受请求的逻辑名和飞书归一化后的本地 basename，最终记录云端实际名称；每张图片仍须具有 `token/src/url/href` 资源。
- revision 漂移、锚点失效、结构异常：停止并保留 batch，不覆盖。
- 图片块没有 token/src/url/href：不推进状态；只处理缺失项。
- 历史图片、妙记或续会内容早于工作文档尾部：不追加补丁标题；标记 `requires_document_rebuild`，在收尾阶段由 canonical groups 生成新成品文档。
- OCR 失败：时间语义明确时保留图片并标“标题待识别”，否则进入 review queue。
- 忠实度失败：拆小时间段、补回解释/案例/条件；不得降低 80%/75% 阈值。

## 脚本边界

现有 Ruby 脚本负责课中 v5 采集、增量、游标、重建标记及忠实度检查，入口见脚本文件名。`render_final_document.rb`、`publish_final_document.rb`、`validate_session.rb` 是旧 v5 成品工具，不能直接当作新的通用课后流水线：旧渲染器逐组显示时间且限制章数，旧验收要求直播字段和逐条时间标签。新版共同成品按 [finalization.md](finalization.md) 的合同在课程工作目录生成、发布并验收；不要为通过旧脚本而伪造直播记录或恢复旧排版。
