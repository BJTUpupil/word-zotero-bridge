# Word Zotero Bridge

面向 Microsoft Word 与 Zotero 的本地批量引文桥接工具。控制器只在项目内的 Word 副本中定位引文，Zotero 插件负责调用原生 Word 集成；引文字段、编号和文后参考文献均由 Zotero 生成。

当前版本固定适配 **Zotero 9.0.6 + Windows 版 Microsoft Word**，支持：

- 插入新的原生 Zotero 引文；
- 将现有引文中的旧条目重关联到规范条目；
- 每项操作后按 Zotero 条目 Key 序列校验；
- 失败后重置桥接会话，并通过 `-Resume` 续跑已保存的副本。

## 安全边界

- 目标 Zotero 集合固定为 `MC8W6IIE`。
- 插件不创建、删除、合并或修改 Zotero 条目。
- 插件不直接拼装 Word 域代码，字段写入由 Zotero 原生集成完成。
- 源 DOCX 保持不变，目标只能位于 `PROJECT\.word-zotero-bridge\work\`。
- 日志只能位于 `PROJECT\.word-zotero-bridge\journal\`。
- 通信复用 Zotero 本地服务，不使用外部代理或额外端口。
- 不使用 LibreOffice，不直接编辑 Zotero 数据库。

## 批次格式

参见 [controller/batch.example.json](controller/batch.example.json)。替换任务必须排在插入任务之前。

替换任务使用以下稳定定位信息：

- `fieldOrdinal`：该字段在所有 Zotero 引文字段中的序号；
- `expectedKeys`：修改前引文条目 Key 的有序列表；
- `replacements`：旧 Key 与目标条目的对应关系。

控制器在执行前核对 `fieldOrdinal` 对应的 Key 序列。执行后只比较各字段的 Key 序列，不依赖 Zotero 可能重建的 `citationID`、格式化引文文本或可变的字符位置。

插入任务使用文本锚点、出现次数和插入方向。每次定位均重新搜索当前文档，不复用前一操作的字符位置。

## 运行

只验证批次：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\controller\Invoke-CitationBatch.ps1 -BatchPath .\controller\batch.json
```

创建副本并执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\controller\Invoke-CitationBatch.ps1 -BatchPath .\controller\batch.json -Apply
```

失败后续跑现有副本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\controller\Invoke-CitationBatch.ps1 -BatchPath .\controller\batch.json -Apply -Resume
```

控制器在每项原生操作前写入待处理状态，保存并验证成功后写入完成状态。若执行中断，续跑会检查目标字段是否已经达到预期状态，避免重复执行。

## 开发与发布

```powershell
npm test
python build.py
python build.py --check
```

发布前必须在目标 Zotero 与 Word 版本上完成真实副本测试。
