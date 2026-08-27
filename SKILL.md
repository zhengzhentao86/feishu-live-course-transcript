---
name: feishu-live-course-transcript
description: 把飞书课程群内的全部 PPT 截图与一场或多场续会的实时/正式逐字稿按统一课程时间和语义对齐，默认两分钟增量更新工作文档，并在课程结束后生成按主题分章的正式成品文档。会先检查群访问、智能体入会与实时字幕，迟到启动或历史缺口进入重建而不是尾部补丁；只删口水词和无关杂音，不把讲解压成摘要。用户提到上课拍 PPT 到群、飞书会议逐字稿配图、实时整理课程、连续换会、补历史图片或课程结束生成完整讲义时必须使用，即使没有明确说 Skill。
---

# 飞书现场课逐字稿整理

## 主动调用时先给使用指引

先简短告诉用户：建课程群并加入已登录账号；开启飞书会议和实时转写；按讲解顺序把 PPT 拍进群；默认新建文档；没有新图也会持续补充新增逐字稿。随后披露：会把指定课程群的 PPT、对应会议或妙记课程转写和讲师姓名写入新的飞书云文档，不写无关群消息、密钥或本地私人资料。

每堂新课只确认一次。用户明确确认后记录 consent；恢复、自动增量和最终收尾沿用该同意。自动心跳不重复指引或披露。

## 两级预检

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

## 不可变质量与安全基线

1. 默认每堂课新建文档；只有用户明确要求才追加旧文档。
2. 每个图文组严格对应“讲师课程时间戳 + 1—N 段忠实精修逐字稿 + 图片”。连续多图先用 OCR 标题、页面正文、发送顺序和转写句意拆成多个“一段相关讲解 + 一张图”的单图组；不能仅因图片连续发送就合并。只有同页重拍、总览页组，或讲师用一段不可可靠拆分的总括讲解同时说明多图时，才使用一个正文只出现一次的并排 `image_group`，并记录不能拆分的语义原因。
3. 没有新图片时，也要持续写新增课程逐字稿；两张图之间未配图的讲解写纯文本条目。
4. 只删口水词、立即自我纠正、逐字重复和无关课堂杂项；保留原顺序、案例、数字、条件、转折、原因、推演、问答和结论，禁止摘要化。
5. 每个自然段不超过 230 个中文字符；内容多时拆段或拆成连续 1—3 分钟条目，不能删信息。
6. 每个条目保存 `source_text`；正文/source_text 字符保留率不得低于 80%，至少 75% 正文字符能按原顺序在原文找到依据。
7. 关键术语、方法、结论和步骤用 `[[...]]` 标记，由脚本转为蓝色加粗；不整段高亮。
8. 所有飞书读取、下载、创建、写入和验收只用 `lark-cli`，不得用浏览器绕过。
9. 用 message ID、图片 resource key、transcript ID、课程时间、时间/位置游标和本地索引保证幂等。新课第一轮必须从课程开始时间建立群图片全量基线；之后才只扫增量。不得因 photographer 为空漏掉历史图片。
10. 每批只写一次，只局部回读本批尾部一次。revision 漂移、结构异常、图片资源为空时立即停止，禁止覆盖或盲目重试。
11. 正式妙记只在确认整门课结束后读取一次；普通轮次不得搜索或读取妙记。
12. 最终必须从本地 canonical content groups 生成新的成品文档，而不是在工作文档尾部追加“补全/回填”章节；验证图片数量、顺序、资源、说话人、课程时间、主题章节、段落长度、转写覆盖与重复项，并真实查看第一、中间、最后一张图片。

## 资源路由：冷热分离

- 新课初始化或用户询问用法：读取 `references/usage-guide.md`、`references/session-state.md`。
- 首次安装、换电脑或环境报错：运行 `scripts/preflight.rb`，只在需要解释时读取 `references/usage-guide.md` 的环境准备部分。
- 普通 2 分钟热路径：只读取本文件、`references/hot-path-contract.md`、state 路径和脚本输出的 compact manifest；不要加载完整风格、安装、历史失败或最终验收说明。
- 需要修正忠实度或版式时：才读取 `references/style-standard.md`。
- 确认整门课结束时：才读取 `references/finalization.md` 并执行最终验收。

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
   - 群消息：`last_message_scan_end` 到当前时间的完整 ISO 8601 窄窗口，`--order asc --page-all --no-reactions`；再按 `message_position > last_message_position` 和本地索引过滤。
   - 会中转写：优先事件 page token，否则只从 `last_transcript_end_time` 到当前时间；禁止从会议开头重拉。
2. 第一轮从 `course_start` 建立课程群图片全量基线；摄影者为空时接收群内全部图片发送者。后续只下载/OCR 本轮新图；已删除图片写入 `unavailable_image_records`。积压超过 6 分钟时只取最早 6 分钟，下一轮续写。
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

## 整门课结束：一次性冷路径

单个会议结束不等于整门课结束。先用原身份检查 active meeting 和群内新的续场会议消息；有新会议时记录 completed session，切换 meeting ID、开始时间和讲师后继续热路径。

只有确认没有续场，才读取 `references/finalization.md`：完成最后增量批次；整堂课只读取一次正式妙记并校正 canonical groups；用 `build_final_outline_context.rb` 让模型只划分主题章节，不改正文；用 `render_final_document.rb` 生成成品 XML，再用 `publish_final_document.rb` 分块创建并自动绑定独立成品文档。随后下载首中尾图片，实际查看并记录视觉验收，运行一次 `validate_session.rb`；通过后用 `complete_session.rb` 标记完成。

## 故障边界

- lark-cli 不可用、未登录、权限、网络或资源失败：说明并停止；不得换浏览器或升级模型。
- 写入超时：按本批唯一时间戳、图片名和 revision 局部回读；确认未落地才重试，不能重写整批。
- 写入结果不确定但局部回读证明本批已完整落地时，只允许使用 `append_batch.rb --recover-existing` 提交状态，不得再次上传。恢复不能假设 revision 只增加 1：含图片的单次更新可能触发多次内部 revision；必须要求云端 revision 大于本地记录、本批时间戳/正文/章节/图片数量与顺序精确匹配、并且本批恰好位于旧尾锚点之后。图片名称同时接受请求的逻辑名和飞书归一化后的本地 basename，最终记录云端实际名称；每张图片仍须具有 `token/src/url/href` 资源。
- revision 漂移、锚点失效、结构异常：停止并保留 batch，不覆盖。
- 图片块没有 token/src/url/href：不推进状态；只处理缺失项。
- 历史图片、妙记或续会内容早于工作文档尾部：不追加补丁标题；标记 `requires_document_rebuild`，在收尾阶段由 canonical groups 生成新成品文档。
- OCR 失败：时间语义明确时保留图片并标“标题待识别”，否则进入 review queue。
- 忠实度失败：拆小时间段、补回解释/案例/条件；不得降低 80%/75% 阈值。

## 脚本入口

- 首次环境检查/安装引导：`preflight.rb`
- 初始化：`init_session.rb`
- 课程现场预检/可选独立入会：`course_preflight.rb`
- 续场切换：`switch_meeting.rb`
- v4 索引迁移：`migrate_session_v4.rb`
- v5 课程时间与 canonical groups 迁移：`migrate_session_v5.rb`
- 增量采集/OCR：`collect_incremental.rb`
- 增量过滤：`filter_incremental_inputs.rb`
- 模型路由：`route_model.rb`
- 模型上下文：`build_model_context.rb`
- 空轮询游标：`commit_empty_poll.rb`
- batch 构建：`build_batch.rb`
- 忠实度：`validate_fidelity.rb`
- 单批写入/局部回读：`append_batch.rb`
- 妙记标记：`mark_minutes_corrected.rb`
- 成品章节上下文：`build_final_outline_context.rb`
- 成品 XML：`render_final_document.rb`
- 分块发布成品文档：`publish_final_document.rb`
- 发布异常恢复时手动绑定成品文档：`mark_final_document.rb`
- 准备/记录首中尾视觉验收：`prepare_validation_previews.rb`、`record_visual_review.rb`
- 最终验收：`validate_session.rb`
- 完成并停止后续心跳：`complete_session.rb`
