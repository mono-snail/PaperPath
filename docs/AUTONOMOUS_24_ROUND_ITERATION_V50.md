# PaperPath V50：工作副本分流、恢复优先级与验证分享闭环

## 本轮目标

V49 已完成版本归档来源签章。本轮不继续扩展 PDF 能力，而是收敛现有能力的产品逻辑：让用户在 Home、Tasks、Outputs 和文档工作区中始终清楚当前处理的是私密工作副本还是交付产物，并把中断恢复、锁定文档和失效输出放到正确的下一步。

本轮定位：**减少重复记录、空入口和错误分享路径，让已有能力形成更短、更可靠的任务闭环。**

## 24 轮闭环

| 轮次 | 证据 | 实际落地 | 用户价值 |
|---|---|---|---|
| 1 | 提示词仍以 V46 为基线，工程已到 V49 | 复核 V47-V49 文档和当前实现 | 避免重复开发已有能力 |
| 2 | 工作区有大量未提交改动 | 仅做增量修改，不回退或格式化既有代码 | 保护当前开发成果 |
| 3 | 源 PDF 与交付产物缺少统一角色语义 | 新增 `isWorkingCopy` / `isDeliveryArtifact` | 各页面使用同一分类契约 |
| 4 | Home 同时展示源文件与产物 | 默认资料库改为工作副本集合 | 首屏不再重复计数同一任务 |
| 5 | 隐藏产物可能降低可发现性 | 显式搜索仍覆盖全部 PDF | 分流不牺牲查找能力 |
| 6 | 总览统计把产物当作待处理文档 | Command Summary 只统计工作副本 | 状态数字更接近真实工作量 |
| 7 | 已验证扫描产物会再次进入待办 | `needsAttention` 排除交付产物 | 不重复推荐 OCR 或处理 |
| 8 | 锁定 PDF 被计入 OCR 候选 | OCR 统计排除锁定记录 | 推荐与可执行条件一致 |
| 9 | 批量任务可能混入交付产物 | 批量压缩、验证只选择未锁定工作副本 | 批处理输入更可预测 |
| 10 | 合并选择器会混入最终产物 | 合并候选改为工作副本 | 降低误把交付件再次加工的概率 |
| 11 | 推荐任务包可能打开零结果选择器 | 只展示至少支持一份文档的任务包 | 消除无结果入口 |
| 12 | Quick Access 与真实兼容性不一致 | 按当前资料库过滤快捷任务 | 用户点下去即可继续 |
| 13 | 全部文档锁定时仍推荐 OCR 或验证 | Home 主行动优先提示解锁 | 首要阻断原因直接可见 |
| 14 | 中断批量验证隐藏在深层页面 | Home 优先恢复或复核最近批次 | 跨启动继续任务更短 |
| 15 | Office 队列暂停和待复核不够显眼 | Home 主行动前置 Office 恢复与复核 | 生产任务不再静默搁置 |
| 16 | Outputs Sources 重复展示已有当前产物的来源 | 有当前 Verified Output 的来源退出 Sources | 输出看板更接近流水线状态 |
| 17 | 批量失败卡片统一重启，丢失失败语义 | 按需复核、失败、停止、阻断分别路由 | 恢复动作直达真正问题 |
| 18 | 被新产物替代的旧输出仍留在 Review | 识别更新的 Verified Output 并退出旧 Review | 避免重复处理旧产物 |
| 19 | 失效 Receipt 从最初来源重新验证 | 改为验证当前已变更输出字节 | 用户修改不会在重验时丢失 |
| 20 | 重验可重复提交且页面退出后继续运行 | 增加任务占用、禁用状态和取消传播 | 防止重复产物与无主任务 |
| 21 | 原来源只能找到直接子产物 | 增加带修订校验和环保护的多级来源链 | 重验后的最新产物仍可从来源找到 |
| 22 | iPad 最近文档混合不同角色，Receipt 同页跳转不关闭 Sheet | 最近记录按角色过滤，同页定位先关闭 Sheet | 上下文切换更稳定 |
| 23 | 历史 Safe Share 会错误触发直接分享工作副本 | 推荐与执行都要求当前 Verified Output；锁定加密 PDF 保留显式例外 | 普通分享路径不再绕过验证 |
| 24 | 多模块修改需要编译和资源门禁 | 完成 strings/plist/diff 校验及两个 scheme 双架构构建 | 当前工程保持可交付状态 |

## 核心变化

### 工作副本与产物分流

- Home、任务选择器、合并、批量压缩和批量验证默认只处理工作副本。
- Outputs 专门承载生产中、待复核和已验证产物。
- 搜索保留跨角色能力，用户仍可按名称找到历史产物。
- 最近文档按当前角色过滤，避免编辑上下文和交付上下文互相干扰。

### 下一步与恢复

- Home 主行动按批量恢复、Office 队列、锁定文档、任务 checkpoint、到期和推荐任务排序。
- 锁定资料库不再给出无法执行的 OCR 或 Verify。
- 推荐任务包和 Quick Access 只展示真实有兼容文档的入口。
- Outputs 批量卡片根据证据页、可恢复失败或源文件阻断状态定向跳转。

### Verified Output 闭环

- 失效输出基于当前文件重新验证，不回退到最初来源。
- 多级来源链逐级校验 `sourceRevisionID`，并通过 visited set 阻止循环。
- 旧 Receipt 可打开最新替代产物，不再重复创建相同副本。
- `.shareCopy` 推荐依赖当前可解析的 Verified Output，不再依赖历史 `completedActions`。
- 执行层再次检查当前 Verified Output，防止过期 UI 状态分享工作副本。
- 锁定 PDF 的显式“分享加密 PDF”保留，不把加密原件误称为已验证产物。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Views/LibraryView.swift`
- `PaperPath/Views/DocumentOutputSheets.swift`
- `PaperPath/Views/CombineDocumentsView.swift`
- `PaperPath/Views/DocumentWorkspaceView.swift`
- `PaperPath/Views/DeliveryReceiptView.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `PaperPathTests/PaperPathTests.swift`

## 编译与静态校验

执行：

```bash
xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project PaperPath.xcodeproj -scheme PaperPathShareExtension -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
git diff --check
plutil -lint PaperPath/Resources/zh-Hans.lproj/Localizable.strings PaperPath/Info.plist PaperPathShareExtension/Info.plist
```

结果：

- `PaperPath` scheme：**BUILD SUCCEEDED**。
- `PaperPathShareExtension` scheme：**BUILD SUCCEEDED**。
- 主 App 与 Share Extension 均生成 arm64 + x86_64 Simulator 产物。
- Share Extension 嵌入与二进制验证成功。
- strings、plist 和 diff 静态检查通过。
- 仅保留既有 AppIntents 元数据跳过警告。
- 按本轮约束未运行单元测试、UI 测试、截图回归或发布门禁。

## 竞争优势

- 同一份工作不会在首页、待办和输出中心被重复表达。
- “可分享”由当前修订和真实产物共同证明，不由历史按钮记录推断。
- 中断批量与 Office 生产进入首要恢复路径，强化移动端长任务连续性。
- 输出修改、重新验证和来源追溯形成多级闭环，同时保持全部处理在本机。

## 未验证风险

- 多级来源链、批量恢复和旧产物替代仍需真实大资料库样本验证性能。
- 锁定 PDF、第三方密码 PDF 和 Share Sheet 生命周期仍需真机验证。
- 本轮没有执行自动化测试，更新的分享推荐契约尚未通过测试运行确认。
- iPad 多窗口、极端 Dynamic Type 与 VoiceOver 完整流程仍需设备级走查。

## 下一阶段

1. 在两台真机覆盖锁屏、密码 PDF、Share Extension 和大批量恢复。
2. 采集 Home 主行动到任务完成的点击数与中断恢复成功率。
3. 对 500-1000 份记录资料库测量来源链解析、搜索和 Outputs 看板刷新成本。
4. 在发布门禁中运行现有核心契约、UI 回归和中文资源完整性检查。
