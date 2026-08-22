# PaperPath V62：跨设备 Bates PDF 字节匹配

## 本轮目标

V61 可导入外部签名凭据，但来自另一设备时记录 ID 通常无法关联。本轮允许用户选择实际 PDF，以流式 SHA-256 直接匹配凭据中的编号结果和编号前源文件；文件名只用于展示，不参与信任判断。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 定义外部 PDF 候选模型 | 文件证据拥有明确边界 |
| 2 | 定义结果、源文件、缺失和歧义状态 | 结论不再只有成功或失败 |
| 3 | 定义逐凭据条目匹配结果 | 每段 Bates 可单独核对 |
| 4 | 独立记录未识别候选文件 | 多选错文件可立即发现 |
| 5 | 单次限制最多 64 份 PDF | 避免无界文件提供商任务 |
| 6 | 限制单文件 1 GB、批次 8 GB | 极端输入提前关闭 |
| 7 | 每份文件单独获取并释放安全作用域 | 不长期持有 Files 权限 |
| 8 | 以 1 MB 缓冲流式计算 SHA-256 | 不把大 PDF 整体载入内存 |
| 9 | 每个读取循环传播取消 | 用户可停止慢速云文件 |
| 10 | 提供文件数和字节级总体进度 | 大批匹配状态准确 |
| 11 | 用 output SHA-256 确认编号交付文件 | 跨设备验证最终 PDF |
| 12 | 用 source SHA-256 识别编号前版本 | 避免把源文件误当交付结果 |
| 13 | 检测重复候选和共享哈希歧义 | 不在多重匹配时武断通过 |
| 14 | 文件名仅作为标签展示 | 重命名不影响验证结论 |
| 15 | 外部凭据详情增加 Match PDF Files | 核心动作就近出现 |
| 16 | 使用系统 Files 支持 PDF 多选 | 可直接检查交付文件夹内容 |
| 17 | 匹配时冻结关闭并提供 Stop | 生命周期和取消行为明确 |
| 18 | 新增按凭据顺序排列的结果页 | 法务材料可逐项扫描 |
| 19 | 展示额外文件、大小和短指纹 | 混入文件可定位 |
| 20 | 支持关闭结果后重新选择文件 | 重试不必重新导入凭据 |
| 21 | 明确字节匹配不是法律认证 | 不扩大可信边界 |
| 22 | 覆盖空选择、文件变化和权限失败 | 失败关闭且不保留权限 |
| 23 | 补齐 VoiceOver、Dynamic Type 和简体中文 | 多设备交互一致 |
| 24 | 更新 README、静态检查与构建证据 | 产品声明保持准确 |

## 核心变化

- 外部签名凭据可选择 1 至 64 份 PDF 做跨设备字节匹配。
- 每份文件按块读取并计算 SHA-256，单文件最多 1 GB、整批最多 8 GB。
- 输出哈希匹配标记为 Numbered，源哈希匹配明确标记为 Source。
- 多候选、共享哈希、缺失和未识别文件均单独呈现。
- 文件名不参与匹配，重命名不会造成错误失效。
- 匹配过程不复制、不导入、不修改所选 PDF。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 候选文件、条目匹配、结果报告和字节进度。
- `PaperPath/Services/DocumentStore.swift`
  - 有界预检、安全作用域、流式哈希、歧义检测和匹配算法。
- `PaperPath/App/PaperPathModel.swift`
  - 匹配任务与进度编排。
- `PaperPath/Views/BatchBatesNumberingView.swift`
  - PDF 多选、停止、结果工作台、重选和未识别文件。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - V62 简体中文资源。
- `README.md`
  - 更新字节级匹配能力。

## 编译结果

标准 Scheme 仍因本机缺少 iOS 26.2 Simulator 平台而无法解析。目标级构建命令：

```bash
xcodebuild -quiet -project PaperPath.xcodeproj -target PaperPath -configuration Debug -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO SUPPORTED_PLATFORMS=iphonesimulator EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets
xcodebuild -quiet -project PaperPath.xcodeproj -target PaperPathShareExtension -configuration Debug -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO SUPPORTED_PLATFORMS=iphonesimulator EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets
```

- 主 App、内嵌及独立 Share Extension：编译成功。
- 产物：`arm64`、`x86_64`。
- 未运行单元测试、UI 测试或截图回归。

## 竞争优势

PaperPath 当前可证明的新优势，是在 iPhone/iPad 本地用签名 Bates 清单直接核对另一设备交付的 PDF 字节，同时区分编号结果、源文件、缺失、歧义和额外文件。该结论不代表法律认证或整体产品全面领先。

## 未验证风险

- 8 GB 上限下的真实文件提供商延迟、能耗和取消尾延迟尚未真机测量。
- 安全作用域文件在读取期间被第三方提供商替换时会失败，但尚未做故障注入。
- 当前仅按完整文件 SHA-256 匹配，不接受内容等价但字节不同的重写 PDF。

## 下一阶段

1. 真机验证 iCloud Drive、SMB 和第三方文件提供商。
2. 评估批量移除 Bates 与反向签名凭据。
3. 为匹配报告增加可选导出，不把结果误称为第三方认证。
