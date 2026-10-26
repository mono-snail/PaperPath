(() => {
  const normalizeLocale = (value) => {
    const locale = String(value ?? "").toLowerCase();
    if (/^zh-(hant|tw|hk|mo)/.test(locale)) return "zh-Hant";
    if (locale.startsWith("zh")) return "zh-Hans";
    if (locale.startsWith("ja")) return "ja";
    if (locale.startsWith("ko")) return "ko";
    if (locale.startsWith("en")) return "en";
    return null;
  };

  const parameters = new URLSearchParams(window.location.search);
  const explicitLocale = normalizeLocale(parameters.get("lang"));

  if (explicitLocale) {
    try {
      window.localStorage.setItem("paperpath.locale", explicitLocale);
    } catch {
      // Browser privacy settings may disable persistent storage.
    }
  }

  const isCrawler =
    /bot|crawler|spider|slurp|bingpreview|facebookexternalhit/i.test(
      window.navigator.userAgent
    );
  if (isCrawler && !explicitLocale) return;

  let savedLocale = null;
  try {
    savedLocale = normalizeLocale(
      window.localStorage.getItem("paperpath.locale")
    );
  } catch {
    // Continue with browser language negotiation.
  }

  const browserLocale = (
    window.navigator.languages ?? [window.navigator.language]
  )
    .map(normalizeLocale)
    .find(Boolean);

  const locale = explicitLocale ?? savedLocale ?? browserLocale ?? "en";
  const isPrivacyPage = /\/privacy(?:\/index\.html)?\/?$/.test(
    window.location.pathname
  );
  const routes = isPrivacyPage
    ? {
        "zh-Hans": "/privacy/",
        "zh-Hant": "/zh-hant/privacy/",
        en: "/en/privacy/",
        ja: "/ja/privacy/",
        ko: "/ko/privacy/"
      }
    : {
        "zh-Hans": "/",
        "zh-Hant": "/zh-hant/",
        en: "/en/",
        ja: "/ja/",
        ko: "/ko/"
      };

  parameters.delete("lang");
  const query = parameters.toString();
  const suffix = `${query ? `?${query}` : ""}${window.location.hash}`;
  const target = routes[locale] ?? routes.en;

  if (window.location.pathname !== target) {
    window.location.replace(`${target}${suffix}`);
  } else if (explicitLocale) {
    window.history.replaceState(null, "", `${target}${suffix}`);
  }
})();
