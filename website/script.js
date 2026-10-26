const featureContent = {
  "zh-hans": {
    scan: {
      kicker: "自动隐私扫描",
      title: "敏感信息，不再靠肉眼一页页找。",
      copy: "支持的邮箱、电话、日期与文本区域会被归类呈现。点击定位即可回到 PDF 原页复核。",
      points: [
        "扫描与识别在设备端完成",
        "候选项按类型和页面整理",
        "支持零选择、全选与逐项选择"
      ],
      image: "privacy-review.webp",
      alt: "PaperPath 隐私扫描候选项复核界面"
    },
    review: {
      kicker: "明确确认",
      title: "不可恢复的操作，必须先说清楚。",
      copy: "执行前会明确显示范围、页数、遮盖样式和不可恢复风险。确认与取消始终同时可见。",
      points: [
        "支持黑块遮盖与白块移除",
        "显示影响的项目、区域与页面",
        "取消后保留扫描和选择进度"
      ],
      image: "privacy-confirm.webp",
      alt: "PaperPath 永久脱敏确认界面，明确显示不可恢复风险和取消按钮"
    },
    output: {
      kicker: "核验副本",
      title: "分享的是哪一份，结果页直接告诉你。",
      copy: "PaperPath 生成脱敏副本并重新检查页面，原件保持不变。完成后可直接分享真正核验过的文件。",
      points: [
        "原件与输出副本明确区分",
        "重新打开页面并记录检查结果",
        "支持 PDF 与回执打包交付"
      ],
      image: "verified-copy.webp",
      alt: "PaperPath 显示永久脱敏完成与核验副本分享入口"
    }
  },
  en: {
    scan: {
      kicker: "Automatic privacy scan",
      title: "Find sensitive details without reading every line.",
      copy: "Supported email addresses, phone numbers, dates, and text regions are grouped for review. Jump back to the exact PDF page before acting.",
      points: [
        "Scanning and recognition run on device",
        "Candidates are grouped by type and page",
        "Select none, all, or individual findings"
      ],
      image: "privacy-review.webp",
      alt: "PaperPath privacy scan review showing detected sensitive details"
    },
    review: {
      kicker: "Explicit confirmation",
      title: "Irreversible actions should never be ambiguous.",
      copy: "Before redaction, PaperPath shows the exact scope, pages, appearance, and recovery boundary. Confirm and cancel remain equally clear.",
      points: [
        "Choose black cover or white removal",
        "See affected items, regions, and pages",
        "Cancel without losing review progress"
      ],
      image: "privacy-confirm.webp",
      alt: "PaperPath permanent redaction confirmation with a clear cancellation option"
    },
    output: {
      kicker: "Verified copy",
      title: "Know exactly which file you are about to share.",
      copy: "PaperPath creates a redacted copy and reopens its pages for checks while preserving the original. Share the file you actually reviewed.",
      points: [
        "Original and output remain distinct",
        "Pages are reopened and checks recorded",
        "Share the PDF alone or with its receipt"
      ],
      image: "verified-copy.webp",
      alt: "PaperPath verified redaction result with a share action"
    }
  },
  "zh-hant": {
    scan: {
      kicker: "自動隱私掃描",
      title: "不用再逐頁逐行尋找敏感資料。",
      copy: "支援的電子郵件地址、電話、日期與文字區域會依類型整理。執行前可返回 PDF 原頁確認。",
      points: [
        "掃描與辨識皆在裝置端完成",
        "候選項依類型與頁面整理",
        "可不選、全選或逐項選取"
      ],
      image: "privacy-review.webp",
      alt: "PaperPath 隱私掃描候選項複核畫面"
    },
    review: {
      kicker: "明確確認",
      title: "無法復原的操作，必須先交代清楚。",
      copy: "執行前會顯示範圍、頁數、遮蓋樣式與無法復原的風險。確認與取消始終清楚可見。",
      points: [
        "可選黑色遮蓋或白色移除",
        "顯示受影響的項目、區域與頁面",
        "取消後保留掃描與選取進度"
      ],
      image: "privacy-confirm.webp",
      alt: "PaperPath 永久遮蔽確認畫面，清楚顯示無法復原的風險與取消按鈕"
    },
    output: {
      kicker: "核驗副本",
      title: "分享哪一份檔案，結果頁直接說明。",
      copy: "PaperPath 會建立遮蔽後的副本並重新檢查頁面，同時保留原始檔。完成後可直接分享實際複核過的檔案。",
      points: [
        "原始檔與輸出副本清楚區分",
        "重新開啟頁面並記錄檢查結果",
        "可單獨分享 PDF 或連同回執交付"
      ],
      image: "verified-copy.webp",
      alt: "PaperPath 顯示永久遮蔽完成與核驗副本分享入口"
    }
  },
  ja: {
    scan: {
      kicker: "自動プライバシースキャン",
      title: "機密情報を一行ずつ探す必要はありません。",
      copy: "対応するメールアドレス、電話番号、日付、テキスト領域を分類して表示します。処理前に該当する PDF ページへ戻って確認できます。",
      points: [
        "スキャンと認識はデバイス上で完結",
        "候補を種類とページごとに整理",
        "未選択・全選択・個別選択に対応"
      ],
      image: "privacy-review.webp",
      alt: "PaperPath のプライバシースキャン候補確認画面"
    },
    review: {
      kicker: "明確な確認",
      title: "元に戻せない操作を曖昧にしません。",
      copy: "実行前に対象範囲、ページ、表示方法、復元できないことを明示します。確認とキャンセルは常に同じ画面に表示されます。",
      points: [
        "黒塗りまたは白抜きを選択",
        "対象項目、領域、ページを表示",
        "キャンセルしても確認状況を保持"
      ],
      image: "privacy-confirm.webp",
      alt: "復元できないこととキャンセル操作を明示した PaperPath の墨消し確認画面"
    },
    output: {
      kicker: "確認済みコピー",
      title: "共有するファイルを結果画面で明確に。",
      copy: "PaperPath は墨消し済みコピーを作成してページを再確認し、元のファイルを保持します。実際に確認したコピーをそのまま共有できます。",
      points: [
        "元ファイルと出力コピーを明確に分離",
        "ページを再度開いて確認結果を記録",
        "PDF のみ、または受領記録と共有"
      ],
      image: "verified-copy.webp",
      alt: "PaperPath の墨消し完了結果と確認済みコピーの共有操作"
    }
  },
  ko: {
    scan: {
      kicker: "자동 개인정보 스캔",
      title: "민감한 정보를 한 줄씩 찾을 필요가 없습니다.",
      copy: "지원되는 이메일 주소, 전화번호, 날짜, 텍스트 영역을 분류해 보여 줍니다. 실행 전 해당 PDF 페이지로 돌아가 확인할 수 있습니다.",
      points: [
        "스캔과 인식은 기기에서 처리",
        "후보를 유형과 페이지별로 정리",
        "선택 안 함, 전체, 개별 선택 지원"
      ],
      image: "privacy-review.webp",
      alt: "PaperPath 개인정보 스캔 후보 검토 화면"
    },
    review: {
      kicker: "명확한 확인",
      title: "되돌릴 수 없는 작업은 모호하게 진행하지 않습니다.",
      copy: "실행 전에 범위, 페이지, 표시 방식과 복구 불가 사실을 분명히 보여 줍니다. 확인과 취소는 항상 함께 표시됩니다.",
      points: [
        "검은색 가림 또는 흰색 제거 선택",
        "영향받는 항목, 영역, 페이지 표시",
        "취소해도 검토 진행 상태 유지"
      ],
      image: "privacy-confirm.webp",
      alt: "복구 불가 경고와 취소 버튼이 분명한 PaperPath 영구 가림 확인 화면"
    },
    output: {
      kicker: "검증된 사본",
      title: "어떤 파일을 공유하는지 결과 화면에서 확인하세요.",
      copy: "PaperPath는 가림 처리된 사본을 만들고 페이지를 다시 검사하며 원본은 그대로 보존합니다. 실제로 검토한 파일을 바로 공유할 수 있습니다.",
      points: [
        "원본과 출력 사본을 명확히 구분",
        "페이지를 다시 열고 검사 결과 기록",
        "PDF만 또는 영수증과 함께 공유"
      ],
      image: "verified-copy.webp",
      alt: "PaperPath 영구 가림 완료 결과와 검증된 사본 공유 화면"
    }
  }
};

const htmlLanguage = document.documentElement.lang.toLowerCase();
const documentLanguage = htmlLanguage.startsWith("zh-hant")
  ? "zh-hant"
  : htmlLanguage.startsWith("zh")
    ? "zh-hans"
    : htmlLanguage.startsWith("ja")
      ? "ja"
      : htmlLanguage.startsWith("ko")
        ? "ko"
        : "en";
const assetPrefix = document.body.dataset.assetPrefix ?? "assets/";
const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

document.querySelectorAll("a[lang]").forEach((link) => {
  link.addEventListener("click", () => {
    const locale = link.getAttribute("lang");
    if (!["zh-Hans", "zh-Hant", "en", "ja", "ko"].includes(locale)) return;

    try {
      window.localStorage.setItem("paperpath.locale", locale);
    } catch {
      // Navigation still works when persistent storage is unavailable.
    }

    if (locale !== "zh-Hans") return;

    const destination = new URL(link.href, window.location.href);
    if (!["/", "/privacy/"].includes(destination.pathname)) return;
    destination.searchParams.set("lang", locale);
    link.href = `${destination.pathname}${destination.search}${destination.hash}`;
  });
});

document.body.classList.add("motion-ready");

const header = document.querySelector("[data-header]");
const menuButton = document.querySelector("[data-menu-button]");
const mobileNav = document.querySelector("[data-mobile-nav]");

const updateHeader = () => {
  header?.classList.toggle("is-scrolled", window.scrollY > 16);
};

updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

const closeMenu = () => {
  if (!menuButton || !mobileNav) return;
  menuButton.setAttribute("aria-expanded", "false");
  menuButton.setAttribute(
    "aria-label",
    menuButton.dataset.openLabel ?? "Open navigation"
  );
  mobileNav.classList.remove("is-open");
  document.body.classList.remove("menu-open");
};

menuButton?.addEventListener("click", () => {
  const willOpen = menuButton.getAttribute("aria-expanded") !== "true";
  menuButton.setAttribute("aria-expanded", String(willOpen));
  menuButton.setAttribute(
    "aria-label",
    willOpen
      ? (menuButton.dataset.closeLabel ?? "Close navigation")
      : (menuButton.dataset.openLabel ?? "Open navigation")
  );
  mobileNav?.classList.toggle("is-open", willOpen);
  document.body.classList.toggle("menu-open", willOpen);
});

mobileNav?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", closeMenu);
});

window.addEventListener("resize", () => {
  if (window.innerWidth > 960) closeMenu();
});

const revealElements = [...document.querySelectorAll(".reveal")];

if (prefersReducedMotion || !("IntersectionObserver" in window)) {
  revealElements.forEach((element) => element.classList.add("is-visible"));
} else {
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
  );

  revealElements.forEach((element) => revealObserver.observe(element));
}

const featureTabs = [...document.querySelectorAll("[data-feature-tab]")];
const featurePanel = document.querySelector(".privacy-panel");
const featureDevice = document.querySelector(".feature-device");
const featureImage = document.querySelector("[data-feature-image]");
const featureKicker = document.querySelector("[data-feature-kicker]");
const featureTitle = document.querySelector("[data-feature-title]");
const featureCopy = document.querySelector("[data-feature-copy]");
const featurePoints = document.querySelector("[data-feature-points]");

const selectFeature = (key, moveFocus = false) => {
  const content = featureContent[documentLanguage][key];
  const selectedTab = featureTabs.find((tab) => tab.dataset.featureTab === key);
  if (!content || !selectedTab) return;

  featureTabs.forEach((tab) => {
    const selected = tab === selectedTab;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });

  featureDevice?.classList.add("is-changing");

  window.setTimeout(() => {
    if (featureKicker) featureKicker.textContent = content.kicker;
    if (featureTitle) featureTitle.textContent = content.title;
    if (featureCopy) featureCopy.textContent = content.copy;
    if (featurePoints) {
      featurePoints.replaceChildren(
        ...content.points.map((point) => {
          const item = document.createElement("li");
          item.textContent = point;
          return item;
        })
      );
    }
    if (featureImage) {
      featureImage.src = `${assetPrefix}${content.image}`;
      featureImage.alt = content.alt;
    }
    featurePanel?.setAttribute("aria-labelledby", selectedTab.id);
    featureDevice?.classList.remove("is-changing");
  }, prefersReducedMotion ? 0 : 130);

  if (moveFocus) selectedTab.focus();
};

featureTabs.forEach((tab, index) => {
  tab.tabIndex = tab.getAttribute("aria-selected") === "true" ? 0 : -1;
  tab.addEventListener("click", () => selectFeature(tab.dataset.featureTab));
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowRight", "ArrowLeft", "ArrowDown", "ArrowUp"].includes(event.key)) return;
    event.preventDefault();
    const direction = ["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : -1;
    const targetIndex = (index + direction + featureTabs.length) % featureTabs.length;
    selectFeature(featureTabs[targetIndex].dataset.featureTab, true);
  });
});

if (featureTabs.length) {
  Object.values(featureContent[documentLanguage]).forEach((item) => {
    const image = new Image();
    image.src = `${assetPrefix}${item.image}`;
  });
}

document.querySelectorAll("[data-language-menu]").forEach((menu) => {
  menu.addEventListener("click", (event) => event.stopPropagation());
});

document.addEventListener("click", () => {
  document.querySelectorAll("[data-language-menu][open]").forEach((menu) => {
    menu.open = false;
  });
});

if (
  !prefersReducedMotion
  && window.matchMedia("(min-width: 961px) and (pointer: fine)").matches
) {
  document.querySelectorAll("[data-tilt]").forEach((device) => {
    const baseRotation = Number(device.dataset.rotation ?? 0);

    device.addEventListener("pointermove", (event) => {
      const bounds = device.getBoundingClientRect();
      const x = (event.clientX - bounds.left) / bounds.width - 0.5;
      const y = (event.clientY - bounds.top) / bounds.height - 0.5;
      device.style.transform = `rotate(${baseRotation + x * 2}deg) rotateX(${-y * 3}deg) rotateY(${x * 3}deg)`;
    });

    device.addEventListener("pointerleave", () => {
      device.style.transform = `rotate(${baseRotation}deg)`;
    });
  });
}
