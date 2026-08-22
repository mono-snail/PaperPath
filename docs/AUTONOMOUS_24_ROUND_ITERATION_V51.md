# PaperPath V51：生产状态收敛、队列恢复与页面任务连续性

## 本轮目标

V50 已完成工作副本与交付产物分流。本轮继续沿真实任务状态收敛产品逻辑，重点修复跨启动队列失真、Outputs 泳道混入普通处理、删除与恢复的部分成功状态，以及页面结构变化后任务位置失效等问题。

本轮定位：**让生产、删除、恢复和页面编辑在中断或对象变化后仍能给出准确且可执行的下一步。**

## 24 轮闭环

| 轮次 | 证据 | 实际落地 | 用户价值 |
|---|---|---|---|
| 1 | V50 报告与当前代码已高于提示词 V46 基线 | 以最新实现复核 Home、Tasks、Outputs 和工作区 | 避免重复开发与过期决策 |
| 2 | 工作区包含大量未提交成果 | 仅增量修改相关模型、存储、视图和资源 | 保护既有功能与用户改动 |
| 3 | Home 的隐私轨道仍用旧来源字段统计 | 统一改用 `workingDocuments` | 首页数量符合工作副本角色契约 |
| 4 | 普通 OCR、附件提取等任务会进入 Outputs Producing | 新增 `deliveryProcessingDocumentIDs` | Outputs 只表达交付生产 |
| 5 | 批量验证的生产中状态缺少独立来源 | 新增 `batchDeliveryPendingDocumentIDs` | 真正活动的批次仍能稳定显示 |
| 6 | 跨启动遗留的非终态批次会伪装成运行中 | 当前批次快照把遗留非终态转换为 Stopped | 不再展示无法继续的虚假进度 |
| 7 | 已删除、已锁定或源修订变化的批次项目仍会出现 | `currentBatchDeliveryRun()` 过滤失效来源和产物 | 批次卡片只保留当前可行动对象 |
| 8 | Outputs 各区各自读取历史批次，口径不一致 | 批次卡片、泳道、查询和空状态统一使用当前快照 | 同一任务不再跨区自相矛盾 |
| 9 | Office 队列启动恢复只恢复阶段，不核对来源 | 启动后统一执行来源有效性对账 | 重启后队列状态可信 |
| 10 | Office 任务无法区分回收站、丢失、锁定和修订变化 | 新增细分来源诊断与 `.attention` 状态 | 用户看到真实阻断原因 |
| 11 | 无效队列任务仍提供不可执行的 Retry | 新增 `canRetryOfficeProductionJob` 门禁 | 菜单动作与实际条件一致 |
| 12 | 回收站来源需要离开队列手动恢复 | 增加 `Restore Source & Retry` 闭环 | 一次操作恢复工作副本并重新排队 |
| 13 | 修订变化任务缺少面向当前内容的恢复路径 | 增加 `Queue Current Revision` | 不再反复重试过期任务 |
| 14 | 终态 Office 任务无法单项治理 | 增加 `Remove Job` 与模型持久化删除 | 队列可持续清理 |
| 15 | Office 入队 UI 可能清空未真正入队的选择 | 入队 API 返回真实成功状态，UI 仅成功后收尾 | 失败后保留用户选择 |
| 16 | 搜索和资料库变化后 Office 选择可能包含失效对象 | 选择集合持续与 eligible working copies 取交集 | 批量操作不携带隐藏脏状态 |
| 17 | 删除可能与文档处理、Office 生产或批量验证并发 | 增加统一删除阻断原因 | 防止生产途中移除源文件 |
| 18 | 单项和批量删除无真实成功返回值 | 删除 API 返回 `Bool`，工作区仅成功后关闭 | 失败时保留上下文并可继续处理 |
| 19 | 删除反馈未区分工作副本和交付产物 | 按角色显示删除结果和回收站说明 | 用户明确原件、工作副本与产物边界 |
| 20 | Restore All 部分成功后同一记录可能同时存在于资料库和回收站 | 单项与全部恢复复用逐项提交逻辑，并重载 sidecar | 部分失败时列表和磁盘保持一致 |
| 21 | Empty Trash 部分失败时 UI 延迟统一更新 | 每成功永久删除一项即同步状态 | 不再显示已不存在的文件 |
| 22 | 删除、移动、重排或插页后 checkpoint 仍指向旧页 | 对各类页面结构变化执行 checkpoint 映射和边界收敛 | 返回任务时仍落在正确页面 |
| 23 | 页面撤销只恢复 PDF 和书签 | Undo 快照保存并恢复任务 checkpoint；文档操作统一独占租约 | 撤销恢复完整工作状态，避免并发写入 |
| 24 | 长任务取消不会传给 detached worker | 拆页、可搜索副本、页面撤销和附件提取接入取消传播与临时文件清理，并完成双 scheme 构建 | 页面退出后不继续提交无主结果 |

## 核心变化

### Outputs 只表达真实交付生产

- 普通文档处理状态不再进入 Producing。
- 活动批量验证使用专用 pending 集合，跨启动遗留任务明确显示为已停止。
- 所有批次视图共用当前有效快照，自动排除已删除、已锁定、修订变化或失效输出。

### Office 队列可诊断、可恢复

- 启动时对工作副本角色、锁定状态、能力支持和源修订进行对账。
- 回收站来源可直接恢复并重试，源修订变化可将当前修订重新入队。
- 只有真实可重试任务显示 Retry，终态任务可单项移除。
- 只有确实新增队列任务后才清空选择和显示成功反馈。

### 删除与恢复保持一致

- 文档处理中、Office 非终态任务中或活动批次中的来源禁止移入回收站。
- 单项和批量删除返回实际成功状态，避免失败后错误退出页面。
- Restore All 和 Empty Trash 都按逐项成功结果更新内存状态。
- 回收站明确区分工作副本与交付产物，并持续说明 Files 原件不受影响。

### 页面任务和异步操作连续

- 删除、移动、重排、插入和替换页面会同步映射任务 checkpoint。
- 存储层刷新再次将 checkpoint 限定在当前页数范围内。
- 页面 Undo 同时恢复 PDF、书签和 checkpoint。
- 写回、版本、OCR、拆页、输出、附件与页面修改使用文档级独占租约。
- 延迟进度回调绑定操作 token，旧任务不能覆盖新任务进度。
- 拆页、可搜索副本、页面 Undo 与附件导出会传播取消；取消时不弹错误并清理临时产物。

## 修改文件

- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Models/DocumentModels.swift`
- `PaperPath/Services/DocumentStore.swift`
- `PaperPath/Views/LibraryView.swift`
- `PaperPath/Views/DocumentWorkspaceView.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `docs/AUTONOMOUS_24_ROUND_ITERATION_V51.md`

## 编译与静态校验

执行：

```bash
xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PaperPath-V51-App-DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project PaperPath.xcodeproj -scheme PaperPathShareExtension -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PaperPath-V51-Share-DerivedData build CODE_SIGNING_ALLOWED=NO
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
- 按迭代约束未运行单元测试、UI 测试、截图回归或发布门禁。

## 竞争优势

- Outputs 从“全局处理中列表”收敛为可信的本地交付生产看板。
- Office 队列不只保存任务，还能解释来源为何失效并提供最短恢复动作。
- 页面编辑、撤销和任务继续使用同一份位置语义，减少复杂文档中的重复定位。
- 删除和恢复采用逐项确认结果，异常中断不会用乐观 UI 掩盖磁盘真实状态。

## 未验证风险

- Office 来源恢复、部分 Restore All 和部分 Empty Trash 仍需真实磁盘故障样本验证。
- 大附件取消、超长 OCR searchable PDF 和大页数 Undo 的响应速度尚未真机测量。
- iPad 多窗口同时编辑同一文档仍需设备级验证独占租约的交互反馈。
- 本轮没有运行自动化测试，页面 checkpoint 映射和队列恢复契约尚未通过测试执行确认。

## 下一阶段

1. 用真机覆盖锁屏、后台取消、低磁盘和回收站来源恢复。
2. 为页面 checkpoint 映射、队列来源对账和部分恢复补齐契约测试。
3. 采集 Office 恢复成功率、批量中断恢复率和删除阻断触发分布。
4. 在 500-1000 份文档资料库上测量当前批次快照与 Outputs 刷新成本。
