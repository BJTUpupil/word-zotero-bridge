# Word Zotero Bridge

面向 Microsoft Word 与 Zotero 的本地批量引文桥接工具。控制器负责在 Word 副本中定位引文位置，Zotero 插件只向原生引文选择流程提供经过核验的条目；引文字段、编号和文后参考文献仍由 Zotero 原生集成生成。

当前版本固定适配 **Zotero 9.0.6 + Windows 版 Microsoft Word**。它支持每批 1—256 个引文位置，能够多次引用同一条目。现有自动测试覆盖批次顺序、集合限制、失败关闭和 55/64 个位置；在完成真实 Word/Zotero 联调前，本项目仍视为试验版本。

## 安装

1. 从仓库的 [dist](dist/) 目录下载 word-zotero-bridge-0.1.0.xpi。
2. 在 Zotero 中打开“工具 → 插件”，选择“从文件安装插件”。
3. 重启 Zotero。

插件更新清单：

    https://raw.githubusercontent.com/BJTUpupil/word-zotero-bridge/main/updates.json

XPI 安装包：

    https://github.com/BJTUpupil/word-zotero-bridge/releases/download/v0.1.0/word-zotero-bridge-0.1.0.xpi

## 工作方式

    批次 JSON
       |
       v
    PowerShell 控制器 -- localhost:23119 -- Zotero 插件
       |                                      |
       |  定位光标、保存、核验                |  核验集合/题名/DOI
       v                                      v
    项目内 Word 副本 <------------ Zotero 原生 Word 集成

- 通信复用 Zotero 自带的本地 HTTP 服务，不另开端口。
- 不使用系统临时目录、文件轮询、浏览器界面或外部代理。
- 插件不创建、删除、合并或修改 Zotero 条目。
- 插件不直接拼装 Word 字段内容；字段写入由 Zotero 原生集成完成。
- 每次插入后，控制器必须保存文档并核验 Zotero 字段数量、条目 Key 和 SHA-256，确认后才能继续。
- 任一提示框、目标文档变化、条目身份变化或执行顺序异常都会终止批次，且不会自动重试。

## 批次文件

参见 [controller/batch.example.json](controller/batch.example.json)。核心字段包括批次 ID、目标集合、项目根目录、只读源文档、目标副本和任务列表。每项任务包含 Zotero Key、完整题名、DOI 及定位信息。

anchor.position 支持：

- before：在指定文本之前插入引文；
- after：在指定文本之后插入引文；
- replace：删除定位标记，并在原位置插入引文。

推荐使用唯一的 [[ZCITE:任务ID]] 标记和 replace 模式。若使用正文文本定位，必须确认指定出现次数不会因前序修改而改变。

## 运行

先只验证批次，不写入：

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\controller\Invoke-CitationBatch.ps1 -BatchPath .\controller\batch.json

确认后执行：

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\controller\Invoke-CitationBatch.ps1 -BatchPath .\controller\batch.json -Apply

执行前须启动 Zotero；Word 由控制器在后台打开。源 DOCX 保持不变，目标文件只能位于：

    PROJECT\.word-zotero-bridge\work\

批次日志只能位于：

    PROJECT\.word-zotero-bridge\journal\

目标副本或同名日志已经存在时，控制器拒绝覆盖。

## 固定安全边界

- 目标 Zotero 集合固定为 MC8W6IIE。
- 每项任务必须同时匹配 Zotero Key、完整题名和 DOI；无 DOI 时传空字符串。
- 只接受目标项目内专用目录中的 DOCX 副本。
- 本地 HTTP 会话令牌在 Zotero 每次启动时重新生成。
- 本地端点不允许浏览器来源绕过 Zotero 的默认请求保护。
- 不支持既有引文字段的重新关联；该任务仍需通过 Zotero 原生功能处理。
- 不支持 LibreOffice，不直接编辑 Zotero 数据库。

## 开发与发布

运行测试：

    npm test

生成可重复的 XPI 和 updates.json：

    python build.py
    python build.py --check

构建脚本固定使用本仓库的 GitHub HTTPS 地址，并为 XPI 生成 SHA-256 更新校验值。发布前还需在目标 Zotero/Word 版本上完成真实副本测试。
