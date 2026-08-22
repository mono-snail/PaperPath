# PaperPath V60：签名 Bates 批次凭据与持续重验

## 本轮目标

V59 已支持跨文档连续 Bates 和可恢复多文件事务，但完成后只有即时提示，无法长期回答“哪些文件使用了哪段编号、当时对应哪个修订、当前文件是否仍与批次一致”。V60 将批次结果升级为本地持久化、Ed25519 签名、可重验和可分享的审计凭据。

本轮不把本机来源签名表述为法律数字签名或第三方认证，也不把“全球领先”作为未经同机任务验证的事实。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 定义 Bates 批次凭据载荷与逐文档条目 | 编号结果拥有稳定数据契约 |
| 2 | 为页码位置补齐 Codable 契约 | 签名载荷可稳定编码和恢复 |
| 3 | 记录每份 PDF 的源修订与结果修订 | 可判断文件是否已在签发后变化 |
| 4 | 记录源文件与结果文件 SHA-256 | 凭据同时覆盖输入和编号结果 |
| 5 | 记录逐文档起止号、总页数和顺序 | 不依赖人工重建批次范围 |
| 6 | 使用本机 Keychain Ed25519 身份签署规范化载荷 | JSON 被修改时签名失效 |
| 7 | 历史限制为最多 24 份、总计 1 MB | 审计元数据保持有界 |
| 8 | 凭据历史通过原子写和完整文件保护保存 | 锁屏与中断边界延续现有策略 |
| 9 | 启动时恢复并执行结构、范围、哈希格式校验 | 畸形历史不会进入界面 |
| 10 | 跨文档 Bates 成功后自动签发凭据 | 不需要用户重复录入批次信息 |
| 11 | 凭据签发失败与 PDF 提交结果分开报告 | 已成功编号不会被误报为回滚 |
| 12 | 重验签名算法、公钥、Key ID 和规范化载荷 | 不只相信本地 JSON 文件 |
| 13 | 重验当前修订并重新计算每份 PDF 指纹 | 状态来自当前字节而非缓存 |
| 14 | 区分 Current、Changed、In Trash、Missing、Untrusted | 异常原因可直接定位 |
| 15 | 新增可搜索的 Bates 凭据历史工作台 | 可按文件名、序列或 Key ID 找回批次 |
| 16 | 新增单份凭据详情和逐文档范围清单 | 每个文件的编号边界与短指纹并列呈现 |
| 17 | 重验按文档显示准确计数、当前文件和进度 | 大批文件不再只有无期限转圈 |
| 18 | 导出包含签名封装的可移植 JSON | 可随交付材料保存或交给其他工具检查 |
| 19 | 导出临时文件使用完整保护并在分享后清理 | 不长期散落敏感文件名与哈希 |
| 20 | 支持删除单份本地凭据 | 治理历史不会修改 PDF 或 Bates 编号 |
| 21 | Bates 批次面板菜单可直达历史 | 连续工作时减少返回和重新查找 |
| 22 | Outputs 工作区增加 Bates receipts 入口 | 审计产物进入正确的信息架构 |
| 23 | 补齐 Dynamic Type、VoiceOver 提示和简体中文 | 小屏、辅助字号和双语路径一致 |
| 24 | 更新 README、静态检查和双架构构建证据 | 保持工程与产品声明同步 |

## 核心变化

### 签名凭据

- 每份凭据记录批次 ID、签发时间、位数、前后缀、位置、总页数和首末编号。
- 每个条目记录历史文件名、页数、编号范围、源/结果修订 ID 和源/结果 SHA-256。
- 规范化 payload 使用已有本机 Ed25519 身份签名，导出 JSON 同时包含公钥、Key ID 和签名。
- 凭据只保存在 App 本地，不加入 iCloud KVS。

### 持续重验

- 打开详情即验证签名和全部当前 PDF，也可手动重新验证。
- 签名不合法时不信任条目中的文档引用。
- 当前文件必须同时匹配结果修订 ID 和重新计算的 SHA-256。
- 移入废纸篓但仍匹配的文件单独标记；永久删除显示 Missing。
- 重验只读取索引和文件，不借机清理或修改文档库。

### 专业交互

- 历史支持按文件名、编号序列和签名者 Key ID 搜索。
- 详情并列展示签名信息、分享范围、文档顺序、编号范围、短指纹和当前状态。
- 重新验证显示逐文档进度。
- 从 Outputs、Library 添加菜单和 Bates 批次面板均可访问历史。
- 批次成功且凭据签发完成时直接展示新凭据。
- 删除凭据明确说明不会改变 PDF 或 Bates 编号。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 签名凭据、结构验证、条目状态、重验报告与进度模型。
- `PaperPath/Services/DocumentStore.swift`
  - 有界受保护历史、签发、签名验证、当前字节重验、导出和删除。
- `PaperPath/App/PaperPathModel.swift`
  - 启动恢复、批次后签发、重验进度和历史操作。
- `PaperPath/Views/BatchBatesNumberingView.swift`
  - 凭据历史、详情、搜索、进度、分享、删除和批次完成直达。
- `PaperPath/Views/LibraryView.swift`
  - Outputs 与添加菜单入口。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - V60 简体中文资源。
- `README.md`
  - 更新签名 Bates 批次凭据能力。

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

本机 Xcode 26.3 的 iOS Simulator 26.2 SDK 与已安装 26.5 runtime 仍不匹配，标准目标解析失败。源码使用目标级降级命令验证：

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
- `git diff --check`、工程/plist/strings 语法和重复本地化键检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞争证据

- Adobe Acrobat 官方 Bates 流程公开说明多文件排序、位数、前后缀和输出位置，但该页面未描述移动端本地签名批次清单：
  - https://helpx.adobe.com/africa/acrobat/desktop/edit-documents/apply-bates-numbering/add-bates.html
- PDF Expert 的公开 Bates 流程聚焦 Mac 上的编号外观与范围：
  - https://pdfexpert.com/how-to-add-page-numbers-pdf
- Xodo 的公开批量页眉页脚与 Bates 流程主要面向桌面产品：
  - https://xodo.com/blog/how-to-add-page-numbers-to-pdf

PaperPath 当前可证明的新差异，是在 iPhone/iPad 本地连续编号后保留带源/结果修订和双 SHA-256 的 Ed25519 签名清单，并能持续对当前私有副本重验。公开页面没有说明竞品不存在其他审计能力，因此不能据此宣称整体产品全面领先。

## 未验证风险

- 签发发生在 PDF 批次原子提交之后；若进程在两者之间被强制终止，PDF 已编号但可能没有凭据。
- 签名 JSON 尚未提供 App 内外部导入验证入口。
- 24 份、1 MB 历史边界和 64 个大文件重验尚未做真机耗时、能耗与文件保护故障注入。
- 文件名会在用户主动分享签名 JSON 时离开 App，界面已披露范围，但尚未做用户理解测试。
- Ed25519 是 PaperPath 本机来源签名，不是证书签名、法律认证或可信时间戳。
- 本轮未运行自动化测试；标准 Scheme 仍需匹配 Simulator runtime。

## 下一阶段

1. 将凭据签发并入 V59 多文件提交事务，消除 PDF 已提交但凭据未落盘的极窄窗口。
2. 增加外部签名 Bates JSON 导入验证，并复用现有可信签名者模型。
3. 真机故障注入验证 Keychain 不可用、锁屏、磁盘耗尽和强制退出。
4. 基于真实法务材料评估批量移除 Bates 及其撤销凭据，而不是继续扩张相邻格式选项。
