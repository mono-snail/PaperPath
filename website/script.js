const featureContent = {
  zh: {
    scan: {
      kicker: "自动隐私扫描",
      title: "敏感信息，不再靠肉眼一页页找。",
      copy: "支持的邮箱、电话、日期与文本区域会被归类呈现。点击定位即可回到 PDF 原页复核。",
      points: [
        "扫描与识别在设备端完成",
        "候选项按类型和页面整理",
        "支持零选择、全选与逐项选择"
      ],
      image: "assets/privacy-review.webp",
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
      image: "assets/privacy-confirm.webp",
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
      image: "assets/verified-copy.webp",
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
      image: "../assets/privacy-review.webp",
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
      image: "../assets/privacy-confirm.webp",
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
      image: "../assets/verified-copy.webp",
      alt: "PaperPath verified redaction result with a share action"
    }
  }
};

const documentLanguage = document.documentElement.lang.startsWith("zh") ? "zh" : "en";
const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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
  menuButton.setAttribute("aria-label", documentLanguage === "zh" ? "打开导航" : "Open navigation");
  mobileNav.classList.remove("is-open");
  document.body.classList.remove("menu-open");
};

menuButton?.addEventListener("click", () => {
  const willOpen = menuButton.getAttribute("aria-expanded") !== "true";
  menuButton.setAttribute("aria-expanded", String(willOpen));
  menuButton.setAttribute(
    "aria-label",
    willOpen
      ? (documentLanguage === "zh" ? "关闭导航" : "Close navigation")
      : (documentLanguage === "zh" ? "打开导航" : "Open navigation")
  );
  mobileNav?.classList.toggle("is-open", willOpen);
  document.body.classList.toggle("menu-open", willOpen);
});

mobileNav?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", closeMenu);
});

window.addEventListener("resize", () => {
  if (window.innerWidth > 820) closeMenu();
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
      featureImage.src = content.image;
      featureImage.alt = content.alt;
    }
    featurePanel?.setAttribute("aria-labelledby", selectedTab.id);
    featureDevice?.classList.remove("is-changing");
  }, prefersReducedMotion ? 0 : 130);

  if (moveFocus) selectedTab.focus();
};

featureTabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectFeature(tab.dataset.featureTab));
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowRight", "ArrowLeft", "ArrowDown", "ArrowUp"].includes(event.key)) return;
    event.preventDefault();
    const direction = ["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : -1;
    const targetIndex = (index + direction + featureTabs.length) % featureTabs.length;
    selectFeature(featureTabs[targetIndex].dataset.featureTab, true);
  });
});

Object.values(featureContent[documentLanguage]).forEach((item) => {
  const image = new Image();
  image.src = item.image;
});

if (!prefersReducedMotion && window.matchMedia("(pointer: fine)").matches) {
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
