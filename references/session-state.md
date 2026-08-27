# v5 会话、课程时间、manifest 与 batch 合同

本文件只在初始化、迁移、脚本调试时读取；普通热路径不要放进模型上下文。

## state.json

核心字段：

```json
{
  "version": 5,
  "status": "active|finalizing|completed",
  "chat_id": "oc_xxx",
  "meeting_ids": ["meeting_id"],
  "current_meeting_id": "meeting_id",
  "course_start": "2026-08-15T15:00:00+08:00",
  "meeting_sessions": [{"meeting_id":"meeting_id","label":"上午第1场","start_time":"ISO","end_time":null,"status":"active","event_identity":"user"}],
  "meeting_start": "2026-08-15T15:00:00+08:00",
  "meeting_status": "active",
  "teacher": "讲师姓名",
  "speaker_mode": "single_teacher|multi_speaker",
  "speaker_map": {},
  "photographer": "拍摄者姓名",
  "document": {
    "token": "docx_token",
    "revision": 42,
    "section_title": "课程正文",
    "append_anchor_block_id": "last_verified_block_id"
  },
  "last_message_scan_end": "2026-08-15T15:30:00+08:00",
  "last_message_position": 100,
  "last_transcript_end_time": "2026-08-15T15:30:00+08:00",
  "meeting_event_page_token": "cursor_or_null",
  "indexes": {
    "processed_message_ids": "indexes/processed_message_ids.txt",
    "processed_image_keys": "indexes/processed_image_keys.txt",
    "processed_transcript_ids": "indexes/processed_transcript_ids.txt",
    "ignored_transcript_ids": "indexes/ignored_transcript_ids.txt",
    "processed_segment_ids": "indexes/processed_segment_ids.txt"
  },
  "index_counts": {},
  "content_groups": [],
  "last_course_time_ms": 0,
  "requires_document_rebuild": false
}
```

长 processed ID 不再进入模型。`content_groups` 是 v5 唯一的正文 canonical ledger；`accepted_slides` 只保存逐图资源和消息元数据。换会只重置当前会议的字幕游标，`course_start` 不变，因此成品时间不会重新归零。

## compact manifest

`collect_incremental.rb` 输出：

```json
{
  "meeting": {"meeting_id":"meeting_id","label":"上午第1场","start_time":"ISO","course_start":"ISO","event_identity":"user"},
  "new_images": [{"message_id":"om_x","image_key":"img_x","message_position":101,"create_time":"ISO","local_path":"...","ocr_title":"..."}],
  "unavailable_images": [{"message_id":"om_deleted","message_position":102,"create_time":"ISO","reason":"deleted_image"}],
  "new_transcripts": [{"transcript_id":"t1","start_time":"ISO","end_time":"ISO","speaker":{"name":"讲师"},"text":"课程原话"}],
  "poll": {"last_message_position":101,"last_message_scan_end":"ISO","last_transcript_end_time":"ISO","meeting_event_page_token":null},
  "route": {"new_image_count":1,"new_transcript_chars":120,"transcript_duration_seconds":300,"ambiguous_alignment_count":0,"comments_count":0,"meeting_status":"active","formal_minutes_available":false,"revision_drift":false,"structure_error":false,"previous_validation_failed":false,"retry_count":0}
}
```

完整 lark JSON 只保存在 run 目录，不进入模型。

## 模型输出

模型只输出语义决策：

```json
{
  "assignments": [
    {"kind":"image","message_id":"om_x","transcript_ids":["t1"],"speaker":"讲师姓名","slide_title":"标题1","chapter_title":"主题｜具体内容","paragraphs":["只与该页对应的正文含[[重点]]"]},
    {"kind":"image_group","message_ids":["om_y","om_z"],"transcript_ids":["t2"],"speaker":"讲师姓名","slide_titles":["标题2","标题3"],"alignment_mode":"shared_explanation","alignment_reason":"讲师用同一段总括讲解同时说明这两张总览页，无法可靠拆句","paragraphs":["共享正文只出现一次"]},
    {"kind":"text","transcript_ids":["t2"],"speaker":"讲师姓名","paragraphs":["正文"]}
  ],
  "ignored_transcripts": [{"transcript_ids":["noise_1"],"reason":"设备调试"}]
}
```

模型不得手写 source_text、时间换算、segment ID、图片本地路径、游标或 revision。

## batch.json

`build_batch.rb` 根据 manifest 与模型决策确定性生成完整 batch。它必须保证：每个新 transcript 恰好写入或忽略一次；每张新图恰好出现一次；默认单图单组；多图组必须声明共享讲解和不能拆分的具体原因，正文只出现一次且渲染为栅格；source_text 来自原转写；图片与时间字段来自 manifest；课程时间来自 `course_start`；忠实度门槛通过。

`append_batch.rb` 使用 state revision 一次写入并一次 range fetch。回读成功后先原子保存 `content_groups` 和逐图资源记录，再更新索引。任何新 group 的课程时间早于已验证尾部时必须返回 `historical_backfill_requires_rebuild`，不能继续追加补丁。
