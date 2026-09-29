import fs from "node:fs";
import path from "node:path";

const reportPath = process.argv[2];
if (!reportPath) {
  throw new Error("Usage: node tools/CheckCodeCoverage.mjs <xccov-report.json>");
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const app = report.targets?.find((target) => target.name === "PaperPath.app");
const shareExtension = report.targets?.find(
  (target) => target.name === "PaperPathShareExtension.appex"
);
if (!app || !shareExtension) {
  throw new Error("Coverage report is missing a production target");
}

function aggregate(files) {
  const coveredLines = files.reduce(
    (total, file) => total + file.coveredLines,
    0
  );
  const executableLines = files.reduce(
    (total, file) => total + file.executableLines,
    0
  );
  return {
    coveredLines,
    executableLines,
    lineCoverage: executableLines === 0
      ? 1
      : coveredLines / executableLines
  };
}

function percentage(value) {
  return `${(value * 100).toFixed(2)}%`;
}

function requireCoverage(label, actual, minimum) {
  if (actual < minimum) {
    throw new Error(
      `${label} coverage ${percentage(actual)} is below ${percentage(minimum)}`
    );
  }
  console.log(
    `PASS: ${label} ${percentage(actual)} >= ${percentage(minimum)}`
  );
}

const serviceFiles = app.files.filter((file) =>
  file.path.includes("/PaperPath/Services/")
);
const domainFiles = app.files.filter((file) =>
  file.path.includes("/PaperPath/Services/")
    || file.path.includes("/PaperPath/Models/")
    || file.path.endsWith("/PaperPath/Core/Localization.swift")
);
const adapterExclusions = new Set([
  "DemoPDFBuilder.swift",
  "SecurePasteboard.swift"
]);
const releaseCriticalServices = serviceFiles.filter(
  (file) => !adapterExclusions.has(path.basename(file.path))
);

const services = aggregate(serviceFiles);
const domain = aggregate(domainFiles);
requireCoverage("production services", services.lineCoverage, 0.80);
requireCoverage("domain logic", domain.lineCoverage, 0.80);
requireCoverage(
  "share extension",
  shareExtension.lineCoverage,
  0.55
);

for (const file of releaseCriticalServices) {
  requireCoverage(
    `service ${path.basename(file.path)}`,
    file.lineCoverage,
    0.65
  );
}

const inspection = app.files.find(
  (file) => file.name === "PDFInspectionService.swift"
);
if (!inspection) {
  throw new Error("Coverage report is missing PDFInspectionService.swift");
}
requireCoverage("PDF inspection", inspection.lineCoverage, 0.85);

console.log(
  `INFO: full app ${percentage(app.lineCoverage)}; SwiftUI view bodies are covered by UI journeys, not used as a unit-line release gate`
);
