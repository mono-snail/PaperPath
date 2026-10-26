# 官网 SEO 与首发资料

本次官网实现五语静态正文、各页唯一标题与描述、绝对 canonical、双向 hreflang 与 x-default、15 页 sitemap、robots.txt、图片替代文字、1200×630 社交图、SoftwareApplication 与可见 FAQ 对应的 JSON-LD。正文无需 JavaScript 即可读取，不根据浏览器语言强制跳转。图片压缩为 WebP，首屏主图优先加载，其余延后加载，不请求外部字体。

关键词围绕实际意图安排：iPhone/iPad PDF 编辑、签名、表单、本地 OCR、永久脱敏与文件交付检查。首页强调本机处理、保留原件、检查分享副本。没有堆竞品名称、伪造评分或宣称搜索排名。

正式站点源文件仍以 `https://paperpath.monoware.app` 为规范域名。Sites 提供单独的 owner-private 预览；预览产物使用自己的域名，并设置 noindex 和 robots 禁止抓取，避免重复内容。私密预览的发布不等于正式域名已部署或搜索引擎已收录。

上线时完成：

1. 将 `website/` 静态内容部署到正式域名；`.openai/` 属于 Sites 身份记录，不是公开站点资源。
2. 获得公开 App Store URL 后，将 Coming soon 替换为真实链接，再填写商店 ID 的 Smart App Banner；当前没有使用占位 ID。
3. 核实支持邮箱、隐私主体及政策生效时间。新的自有支持页为 `/support/` 和 `/en/support/`。
4. 在有权限的 Google Search Console / Bing Webmaster Tools 中验证域名并提交 sitemap。无需在站点中加入未知的验证令牌。
5. 检查正式域名 HTTPS、HTTP 到 HTTPS 跳转、真实 404、压缩、缓存和图片 MIME 类型。不要将未知 URL 全部返回首页 200。
6. 用 Search Console URL Inspection 复核抓取与语言版本，用 PageSpeed Insights 测量正式托管的性能。当前未宣称有 Lighthouse 分数或 Core Web Vitals 结果。

没有填入尚不存在的购买 Offer 或评分。SoftwareApplication 用于描述产品；没有满足全部 Google 软件富媒体结果要求，因此不承诺富媒体展现。FAQ 标记与页面可见问答一致，也不承诺出现 FAQ 富媒体结果。

参考（2026-10-26 核对）：[Google 多语言版本](https://developers.google.com/search/docs/specialty/international/localized-versions)、[多语言站点](https://developers.google.com/search/docs/specialty/international/managing-multi-regional-sites)、[软件结构化数据](https://developers.google.com/search/docs/appearance/structured-data/software-app)、[Apple 产品页](https://developer.apple.com/app-store/product-page/)。
