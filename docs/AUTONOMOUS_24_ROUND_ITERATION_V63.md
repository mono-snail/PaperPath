# PaperPath V63：可验证跨文档 Bates 移除

## 本轮目标

V62 已能跨设备匹配 Bates 批次中的 PDF 字节，但跨文档 Bates 仍只能统一添加、不能统一移除；逐份移除会失去批次原子性，也无法证明清除后的文件集合。本轮从原签名凭据发起有界批量移除，并为清除结果附加独立 Ed25519 签名事件。

本轮不修改导入源文件，不把本机来源签名表述为证书签名、法律认证或可信时间戳。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 以 V62 脏工作区为基线并保留全部现有改动 | 不覆盖前序成果 |
| 2 | 复核 V54-V62 能力与最新源码 | 避免重复增加已有入口 |
| 3 | 重跑标准 Scheme 并确认 `actool` 环境阻断 | 区分环境问题和源码问题 |
| 4 | 审计单文档 Bates 定向移除 | 复用成熟的作者标记边界 |
| 5 | 审计多文件事务、日志和回滚 | 不复制另一套写盘实现 |
| 6 | 审计签名凭据与外部验证 | 保持原凭据兼容 |
| 7 | 定义移除凭据与逐文档条目 | 清除结果拥有稳定契约 |
| 8 | 沿用 64 份 PDF、10,000 页上限 | 批量任务保持有界 |
| 9 | 只允许从现有签名批次发起移除 | 操作对象和范围明确 |
| 10 | 按原凭据顺序恢复目标文档 | 不依赖用户重新选择和排序 |
| 11 | 移除前核验签名、修订和 SHA-256 | 已变化文件不会被覆盖 |
| 12 | 每份 PDF 在受保护临时副本中移除 | 准备阶段不触碰工作副本 |
| 13 | 要求每页恰好一个原批次 Bates 标记 | 异常标记数量会失败关闭 |
| 14 | 重开确认 Bates 清零且其他批注签名保持 | 不把成功编码等同于正确结果 |
| 15 | 一次获取全部文档独占租约 | 避免其他任务并发改写 |
| 16 | 复用暂存、回滚和原子写磁盘预算 | 空间不足时不开始发布 |
| 17 | PDF、`library.json` 和凭据历史统一发布 | 文件与审计状态同步切换 |
| 18 | 复用跨启动事务日志和逆序回滚 | 强制退出后可恢复旧集合 |
| 19 | 为整批保留一个 Undo 动作 | 误移除可一次恢复全部 PDF |
| 20 | 独立签署移除时间、前后修订和双哈希 | 原签名保持不变，移除证据可验证 |
| 21 | 凭据详情增加就近移除、确认和进度 | 无需逐份进入文档操作 |
| 22 | 区分 Numbered、Cleared、Source 与混合状态 | 验证结论不再含糊 |
| 23 | 补齐 VoiceOver 状态、简体中文和危险操作禁用 | 小屏与辅助路径保持完整 |
| 24 | 完成资源、差异和双目标双架构编译检查 | 保持发布前工程门槛 |

## 核心变化

### 可恢复批量移除

- 只对仍与原签名编号结果同时匹配修订 ID 和 SHA-256 的完整批次开放移除。
- 每份临时副本必须移除与页数相同数量的 PaperPath Bates 标记。
- 写后重新打开每一页，确认 Bates 标记已清零，其他批注的类型、正文、作者、字段名、印章名和几何签名保持一致。
- 提交前可取消；原子发布开始后只会完整完成或完整回滚。
- 成功后提供整批一步 Undo，并保留每份 PDF 的版本快照。

### 双签名凭据

- 原 `paperpath.bates-batch.v1` payload 与签名保持不变。
- 凭据封装可选附加 `paperpath.bates-removal.v1` payload 和独立 Ed25519 签名。
- 移除条目记录编号结果与清除结果的修订 ID、SHA-256、页数和历史文件名。
- 旧 JSON 缺少可选移除字段时仍可解码；新 JSON 会分别验证编号签名、移除签名和两者的逐文档关联。

### 验证与交互

- 本机重验区分 `Current`、`Removed`、`Changed`、`In Trash`、`Missing` 和 `Untrusted`。
- 若批次中同时存在已编号与已清除文件，明确标为混合状态而不是整体通过。
- 跨设备文件匹配新增 `Cleared PDF matches`，文件名仍只用于展示，结论来自完整文件 SHA-256。
- 移除期间禁止关闭、重验、分享或删除凭据，提供当前阶段、文件和整体进度。
- 历史列表以不同图标和时间标记已移除批次。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 移除凭据模型、移除状态、清除文件匹配和批次进度。
- `PaperPath/Services/PDFMutationService.swift`
  - Bates 定向移除后的非目标批注幸存校验。
- `PaperPath/Services/DocumentStore.swift`
  - 移除凭据签发、双签名验证、原子发布和外部清除哈希匹配。
- `PaperPath/App/PaperPathModel.swift`
  - 批次预检、快照、临时准备、提交、进度和整批 Undo。
- `PaperPath/Views/BatchBatesNumberingView.swift`
  - 凭据内移除入口、确认、状态、进度及历史标识。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - 批量移除和验证状态的简体中文。
- `README.md`
  - 更新跨 PDF Bates 能力说明。

## 编译结果

标准 Scheme 命令：

```bash
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

本机 iOS Simulator 26.2 SDK 与已安装 runtime build 不匹配，标准构建在 Asset Catalog 阶段失败。源码使用目标级降级命令验证：

```bash
xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -target PaperPath \
  -configuration Debug \
  -sdk iphonesimulator \
  build CODE_SIGNING_ALLOWED=NO \
  SUPPORTED_PLATFORMS=iphonesimulator \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets

xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -target PaperPathShareExtension \
  -configuration Debug \
  -sdk iphonesimulator \
  build CODE_SIGNING_ALLOWED=NO \
  SUPPORTED_PLATFORMS=iphonesimulator \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets
```

- `PaperPath`：源码编译与链接成功。
- 独立及内嵌 `PaperPathShareExtension`：源码编译与链接成功。
- 三个产物均包含 `arm64` 和 `x86_64`。
- `git diff --check`、plist、strings 语法和重复本地化键检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞争优势

- 跨文档 Bates 的添加和移除共享本地多文件事务、源修订校验、磁盘预算、跨启动恢复和整批 Undo。
- 清除动作不会重写原签发事实，而是追加独立签名、可导出、可跨设备验证的反向事件。
- 外部验证能区分编号结果、清除结果、编号前源文件、缺失、歧义和额外文件。

这些是当前源码和编译可证明的差异，不代表已经通过同机任务测试证明整体领先 Adobe Acrobat、PDF Expert 或 Xodo。

## 未验证风险

- 尚未在真机对提交阶段强制退出、锁屏、磁盘耗尽和文件保护失败做故障注入。
- 64 份或 10,000 页批量移除的耗时、峰值内存、能耗和取消尾延迟尚未量化。
- PDFKit 重写后的复杂第三方批注外观仍需 Acrobat、Preview、PDF Expert 和 Xodo 互操作验证。
- 当前每个原始 Bates 批次只记录一次签名移除事件；Undo 后不会覆盖历史证据。
- 标准 Scheme 仍需安装与 SDK 匹配的 Simulator runtime 后复跑。

## 下一阶段

1. 真机执行批量移除发布阶段的强制退出与磁盘故障注入。
2. 用真实法律卷宗验证清除前后打印、旋转页、复杂批注和第三方阅读器表现。
3. 为外部字节匹配报告增加受保护的可选导出。
4. 根据真实任务数据决定是否支持移除后的再次编号事件链，避免无界审计历史。
