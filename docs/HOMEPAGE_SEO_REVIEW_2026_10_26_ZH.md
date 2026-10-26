# 官网首屏与 SEO 复核 · 2026-10-26

## 判断

首屏原来偏品牌口号，用户需要继续读才能明确“不上传、离线、无订阅”和常用任务。本轮已将这几项放进首屏。代码层面的 SEO 基础通过本地检查；线上 SEO 仍不能算完成，因为当前 Sites 是受限访问预览，正式域名本次访问超时，尚未验证公开抓取和实际收录。

检查期间部署状态有变化：最初 Sites 无发布版本，结束前已有 version 2 的 live 版本，但访问模式仍是 custom。仓库部署说明也明确该版本是 owner-private、noindex 的预览，生产域名未部署。不能把私有预览的部署成功等同于公开 SEO 上线。本轮没有更改站点权限、DNS 或发布版本。

## 本轮修改

| 项目 | 改进 |
| --- | --- |
| 首屏标题 | 英文由 Private PDFs / Confident handoffs 改为 PDF tools / No uploads；中文明确“PDF 工具，无需上传” |
| 购买理由 | 不上传、离线、无订阅三项移到按钮之前；在 320px 英文页面也优先可见 |
| 功能识别 | 首屏直接说明合并、拆分、压缩、OCR；表单、签名和脱敏作为后续能力，保留原件说明 |
| 行动入口 | 主按钮跳到实际工具区域，价格入口标明价格与上架；不伪造未公开的下载链接 |
| 售价边界 | 保留计划中的 US$9.99，一屏内补上即将上架和计划售价，避免误解为现已可买 |
| 内容 SEO | 五种语言同步更新 title、description 和功能标题，补充离线、合并顺序、压缩质量的真实 FAQ |
| 结构化数据 | PDF 工具类别使用 UtilitiesApplication；不添加虚构评价或尚未可购买的 Offer，FAQ 标记与可见内容一致 |
| 可维护性 | 修改 tools/marketing-copy.json 和页面生成器，再生成 HTML；新增独立 SEO 一致性检查，避免下次生成覆盖修复 |

保留现有视觉方向、实际 App 截图、手动语言切换和无追踪依赖。没有添加“无限文件大小”、启动时间或准确率承诺。

## 验证

`python3 tools/CheckMarketingWebsite.py` 通过：15 个页面的本地链接、素材、标题层级、语言链接、sitemap、JSON-LD 和价格文案等检查。

`python3 tools/CheckHomepageSEO.py` 通过：15 个生产候选页面 self-canonical、按页面类型成组的双向 hreflang、XML/HTML 语言映射一致性、sitemap 与 canonical 集合一致、结构化问答和可见文本一致、社交卡片、首图声明、robots 等检查。

浏览器实际响应式页面：英文 320px、中文 390px 和 1440px，报告的内容宽度等于视口宽度，已加载图片没有损坏；日文 768px亦通过同样检查。非当前宿主视口的检查通过现有 noindex QA iframe 完成，截图保留外围诊断区。首屏截图保存在 `design/homepage-seo-2026-10-26/`。没有将这些检查称作真实移动设备性能测试。

## 上线仍需完成

1. 将生产页面部署到确定的公开域名，并确认匿名访问返回正常的 HTTP 200；私有预览继续保留 noindex。
2. 确认线上 canonical、hreflang、robots、sitemap 都使用最终生产域名，没有带入预览域名或 noindex。
3. 验证 Search Console 所有权，提交 sitemap，用 URL Inspection 查看抓取、选择的 canonical 与收录状态。
4. App Store 公开可用后，再把下载按钮连接到真实上架页面，并基于真实售价更新应用 Offer。
5. 用公开站点测移动性能与 Core Web Vitals，并根据实际搜索展现、查询词和点击数据继续迭代。当前没有这些线上数据，不能保证排名或转化提升。

## 官方依据

Google 要求可公开访问、未阻挡 Googlebot、返回 200 且有可索引内容，满足这些条件也不保证收录：[Google Search 技术要求](https://developers.google.com/search/docs/essentials/technical)。

多语言页面使用各语言 canonical 和完整互相对应的语言版本：[本地化版本说明](https://developers.google.com/search/docs/specialty/international/localized-versions)。

应用 rich result 有其必需字段；普通软件介绍标记不能当作已获得富结果资格：[SoftwareApplication 指南](https://developers.google.com/search/docs/appearance/structured-data/software-app)。FAQ rich results 主要限于符合条件的权威政府和健康网站，不把它作为此产品的搜索展示承诺：[Google FAQ 展示变更](https://developers.google.com/search/blog/2023/08/howto-faq-changes)。
