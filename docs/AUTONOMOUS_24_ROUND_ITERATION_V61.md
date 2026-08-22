# PaperPath V61：原子 Bates 凭据事务与外部验证

## 本轮目标

V60 已生成可持续重验的签名 Bates 凭据，但凭据在 PDF 批次提交后单独落盘，进程在两者之间被终止时可能出现“PDF 已编号、凭据缺失”。同时，导出的 JSON 无法在 PaperPath 内重新导入验证。

V61 将签名凭据并入 PDF 多文件事务，并增加 Files 外部凭据验证，闭合“生成、交付、导入、验签、匹配、保留”的本地证据链。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 在首次事务前创建受保护的空凭据索引 | 首次写入也拥有可回滚旧状态 |
| 2 | 跨启动事务日志覆盖凭据历史文件 | 强制退出后 PDF、索引和凭据一起恢复 |
| 3 | 多文件事务支持额外受保护元数据写入 | 不为每类审计文件复制事务实现 |
| 4 | 磁盘预算加入凭据暂存、旧文件备份和最大写入 | 空间不足在发布前失败 |
| 5 | 在发布前构造逐文档 Bates 凭据载荷 | 不存在提交后再拼接证据的时间窗 |
| 6 | 在发布前完成 Ed25519 签名 | Keychain 不可用时不修改任何 PDF |
| 7 | PDF、凭据历史和 `library.json` 一起暂存 | 发布集合完整 |
| 8 | 依次发布 PDF、凭据历史和文档索引 | 正常路径保持一致性 |
| 9 | 进程内失败逆序恢复全部事务成员 | 不留下部分编号或孤立凭据 |
| 10 | 恢复日志允许最多 64 份 PDF 加两份元数据 | 启动恢复覆盖新事务结构 |
| 11 | 发布后重读历史并确认新凭据存在 | 成功返回前验证真实落盘结果 |
| 12 | 事务直接返回已签发凭据 | 模型不再自行推测最新历史 |
| 13 | 删除提交后的二次签发任务 | 消除 PDF 成功但凭据未创建的窗口 |
| 14 | Undo 继续通过修订和哈希使旧凭据自然显示 Changed | 不篡改历史证据 |
| 15 | Files 导入仅接受 1 MB 内 JSON 普通文件 | 外部输入保持有界 |
| 16 | 对外部 JSON 执行严格 schema、范围和哈希格式校验 | 畸形载荷不会进入验证 UI |
| 17 | 独立验证算法、公钥、Key ID 和 Ed25519 签名 | 不依赖本地历史文件可信 |
| 18 | 对可匹配的本机记录重算当前 SHA-256 | 同设备交付可直接发现后续变化 |
| 19 | 凭据历史工具栏增加 Files 验证入口 | 导入路径清晰且短 |
| 20 | 新增外部凭据结果页和逐文档状态 | 验证结论可扫描、可定位 |
| 21 | 区分本设备、可信签名者、未知来源、无效和不支持 | “签名有效”不等于“身份可信” |
| 22 | 安全作用域读取后立即释放，取消时停止剩余哈希 | 不长期持有外部文件权限 |
| 23 | 补齐导入进度、VoiceOver、Dynamic Type 和简体中文 | 小屏与无障碍路径完整 |
| 24 | 更新 README、资源检查和构建证据 | 产品声明与实际能力一致 |

## 核心变化

### 原子凭据事务

- Bates payload 和 Ed25519 签名在任何工作副本发布前生成。
- 凭据历史与全部 PDF、`library.json` 共享磁盘预算、暂存、备份、事务日志、发布后核验和失败回滚。
- Keychain、签名、历史结构或空间检查失败时，PDF 保持原状。
- App 被终止后，下一次启动会按旧文件指纹恢复 PDF、文档索引和凭据历史。
- 成功结果直接包含事务内签发的凭据，不再执行提交后的异步二次签发。

### 外部凭据验证

- 从 Files 选择 `.json`，仅接收普通文件且上限为 1 MB。
- 安全作用域在读取完成后立即释放。
- 先校验 schema、编号连续性、位数、前后缀、页数、SHA-256 格式和唯一记录 ID。
- 再校验 Ed25519、公钥与 Key ID；无效签名不会启用文档引用动作。
- 若记录 ID 在本设备存在，继续重算当前 PDF 指纹并显示 Current、Changed、In Trash 或 Missing。
- 验证完成后由用户决定是否保留到本地历史，不自动导入。

### 信任表达

- `This device`：当前设备 Keychain 身份。
- `Trusted signer`：已存在于 Office 可信签名者列表且公钥匹配。
- `Unknown signer`：签名在密码学上有效，但来源未被用户信任。
- `Invalid / Unsupported`：载荷、公钥、签名或算法不可接受。
- 界面明确说明来源签名不是证书签名、法律身份或可信时间戳。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 凭据验证报告加入来源信任状态和外部检查结果。
- `PaperPath/Services/DocumentStore.swift`
  - 原子凭据事务、恢复、容量预算、外部解析、验签和保留。
- `PaperPath/App/PaperPathModel.swift`
  - 使用事务返回凭据并编排外部检查与保留。
- `PaperPath/Views/BatchBatesNumberingView.swift`
  - Files 导入、验证进度、外部结果页和信任说明。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - V61 简体中文资源。
- `README.md`
  - 更新原子 Bates 和外部凭据验证能力。

## 编译结果

标准 Scheme 命令仍因本机缺少匹配的 iOS 26.2 Simulator 平台而在目标解析阶段失败：

```bash
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

源码使用目标级命令验证：

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

- 主 App、内嵌 Share Extension 和独立 Share Extension：源码编译与链接成功。
- 产物架构：`arm64`、`x86_64`。
- `git diff --check`、工程/plist/strings 语法和本地化重复键检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞争证据

- Adobe Acrobat 官方 Bates 流程说明多文件顺序、编号参数和输出位置，但公开页面未描述移动端本地原子签名批次凭据：
  - https://helpx.adobe.com/africa/acrobat/desktop/edit-documents/apply-bates-numbering/add-bates.html
- PDF Expert 的公开 Bates 流程聚焦 Mac 端编号外观和范围：
  - https://pdfexpert.com/how-to-add-page-numbers-pdf
- Xodo 的公开批量 Bates 流程主要面向桌面产品：
  - https://xodo.com/blog/how-to-add-page-numbers-to-pdf

PaperPath 当前可证明的新差异，是在 iPhone/iPad 本地将 PDF 字节、文档索引和签名批次凭据作为一个可跨启动恢复的事务发布，并能重新导入 JSON 区分密码学有效性、来源信任与当前文件一致性。公开页面不能证明竞品不存在其他审计能力，因此不宣称整体全面领先。

## 未验证风险

- 尚未通过真机强制杀进程验证包含凭据历史的三类事务成员恢复。
- iCloud Drive、第三方文件提供商和超慢安全作用域文件的导入取消体验尚未实测。
- 外部凭据只能关联同一数据域中的记录 ID；来自另一设备时通常显示 Missing，但签名仍可独立验证。
- 可信签名者仍通过现有 Office 身份卡流程管理，Bates 验证页不直接授予信任。
- Ed25519 来源签名不是证书签名、法律认证或可信时间戳。
- 本轮未运行自动化测试；标准 Scheme 仍需安装匹配 Simulator 平台。

## 下一阶段

1. 真机执行签名后、凭据发布后、索引发布前的分阶段强制退出故障注入。
2. 为外部凭据增加可选的独立 PDF 文件匹配，不只依赖本机记录 ID。
3. 评估批量移除 Bates 及其反向凭据，保持与原子事务同等级别。
