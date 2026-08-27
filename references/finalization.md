# 整门课结束后的唯一收尾

1. 先区分会议结束与课程结束：用原身份检查 active meeting，并增量检查课程群的新会议消息；有续场就运行 `switch_meeting.rb`，保留同一个 `course_start` 和工作文档继续热路径。
2. 确认整门课结束后把状态改为 `finalizing`，只补一次最后增量批次。
3. 整堂课只搜索和读取一次正式妙记。妙记用于校正 canonical `content_groups` 的错字、专名、说话人、缺失尾段和历史缺口；不得在工作文档尾部追加“补全/回填”章节。
4. 用 `mark_minutes_corrected.rb` 绑定妙记 ID、校正 batch 和工作文档最终 revision。若存在 `requires_document_rebuild=true`，先从全部会议转写、完整群图片清单和用户确认的 speaker map 重建 canonical groups。
5. 运行 `build_final_outline_context.rb`。模型只输出主题章节标题和有序 `group_ids`，不重写正文；章节标题不得出现“第一段、第二段、补全、回填、图片补全、系统修复”等处理痕迹。
6. 运行 `render_final_document.rb`。脚本强制每个 group 恰好一次、课程时间单调、transcript ID 不重复、每张图片恰好一次、正文保留率 ≥80%，并生成“阅读说明 + 主题章节 + 连续课程时间 + 图文组”的成品 XML。单图组保持一段相关讲解配一张图；共享讲解的多图组正文只出现一次，图片按每行最多四张栅格并排。
7. 运行 `publish_final_document.rb`，按最多 8 张图片/60 个顶层块分批使用 lark-cli 创建独立成品文档；每批一次写入、一次局部回读并验证真实图片资源。标题沿用“课程名｜逐字稿 × PPT 完整对照版”。工作文档保留为实时过程记录，不在其上做危险重排。发布成功后脚本自动绑定成品 token、URL 和 revision；只有云端已成功但本地绑定中断时才用 `mark_final_document.rb` 恢复。
8. 运行 `prepare_validation_previews.rb`，它只通过 lark-cli 下载成品文档第一、中间、最后一张图片。Agent 必须实际查看三张本地图片，确认内容可见、文字可读、不是空块或错图，再运行 `record_visual_review.rb --confirm-all-legible --yes`。
9. 只运行一次 `validate_session.rb`：验证物理索引与 canonical state 一致，图片数量、顺序、唯一性和真实资源，课程时间无倒退，主题章节存在，caption 格式稳定，说话人、段落长度、source_text、转写覆盖和重复项均通过，并校验视觉验收文件与当前 revision 一致。
10. 全部通过后运行 `complete_session.rb` 标记 `completed`，把成品文档 URL 交给用户。失败时保留工作文档、成品候选、outline、XML、预览和 state，不降低阈值、不覆盖、不重复全量收尾。
