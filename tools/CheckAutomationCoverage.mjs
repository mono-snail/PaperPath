import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
);
const modelPath = path.join(
  root,
  "PaperPath/Models/DocumentModels.swift"
);
const manifestPath = path.join(
  root,
  "docs/AUTOMATION_COVERAGE.json"
);

function swiftFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        return swiftFiles(entryPath);
      }
      return entry.isFile() && entry.name.endsWith(".swift")
        ? [entryPath]
        : [];
    });
}

function enumCases(source, name) {
  const header = new RegExp(`enum\\s+${name}\\s*:`).exec(source);
  if (!header) {
    throw new Error(`Could not find enum ${name}`);
  }
  const openBrace = source.indexOf("{", header.index);
  let depth = 0;
  let closeBrace = -1;
  for (let index = openBrace; index < source.length; index += 1) {
    if (source[index] === "{") {
      depth += 1;
    } else if (source[index] === "}") {
      depth -= 1;
      if (depth === 0) {
        closeBrace = index;
        break;
      }
    }
  }
  if (closeBrace < 0) {
    throw new Error(`Could not parse enum ${name}`);
  }

  const body = source.slice(openBrace + 1, closeBrace);
  const declarations = body.split(/\n\s*var id\s*:/, 1)[0];
  return declarations
    .split("\n")
    .flatMap((line) => {
      const match = /^\s*case\s+(.+)$/.exec(line);
      if (!match) {
        return [];
      }
      return match[1]
        .split(",")
        .map((value) => value.trim().split(/\s|=/, 1)[0])
        .filter(Boolean);
    });
}

function testNames(source) {
  return new Set(
    [...source.matchAll(/\bfunc\s+(test[A-Za-z0-9_]+)\s*\(/g)]
      .map((match) => match[1])
  );
}

function functionBodies(source) {
  const bodies = new Map();
  const pattern = /\bfunc\s+([A-Za-z0-9_]+)\s*\(/g;
  for (const match of source.matchAll(pattern)) {
    const openBrace = source.indexOf("{", match.index);
    if (openBrace < 0) {
      continue;
    }
    let depth = 0;
    for (let index = openBrace; index < source.length; index += 1) {
      if (source[index] === "{") {
        depth += 1;
      } else if (source[index] === "}") {
        depth -= 1;
        if (depth === 0) {
          bodies.set(
            match[1],
            source.slice(openBrace + 1, index)
          );
          break;
        }
      }
    }
  }
  return bodies;
}

function reachableFunctionSource(name, bodies) {
  const visited = new Set();
  const pending = [name];
  const source = [];
  while (pending.length > 0) {
    const current = pending.pop();
    if (visited.has(current)) {
      continue;
    }
    visited.add(current);
    const body = bodies.get(current);
    if (body === undefined) {
      continue;
    }
    source.push(body);
    for (const candidate of bodies.keys()) {
      if (!visited.has(candidate)
          && new RegExp(`\\b${candidate}\\s*\\(`).test(body)) {
        pending.push(candidate);
      }
    }
  }
  return source.join("\n");
}

function sameMembers(actual, expected) {
  return actual.length === expected.length
    && actual.every((value) => expected.includes(value));
}

const claimedJourneyTests = new Map();

function validateSection({
  sectionName,
  sourceCases,
  entries,
  unitTests,
  uiTests,
  uiFunctionBodies
}) {
  const manifestCases = Object.keys(entries);
  if (!sameMembers(sourceCases, manifestCases)) {
    const missing = sourceCases.filter(
      (value) => !manifestCases.includes(value)
    );
    const stale = manifestCases.filter(
      (value) => !sourceCases.includes(value)
    );
    throw new Error(
      `${sectionName} coverage mismatch; missing=[${missing}] stale=[${stale}]`
    );
  }

  for (const [feature, coverage] of Object.entries(entries)) {
    if (!Array.isArray(coverage.logicTests)
        || coverage.logicTests.length === 0) {
      throw new Error(`${sectionName}.${feature} has no logic test`);
    }
    if (typeof coverage.journeyTest !== "string"
        || coverage.journeyTest.length === 0) {
      throw new Error(
        `${sectionName}.${feature} has no dedicated journey test`
      );
    }
    if (typeof coverage.deviceRequired !== "boolean") {
      throw new Error(
        `${sectionName}.${feature} must declare deviceRequired`
      );
    }
    if ("uiLevel" in coverage || "uiTests" in coverage) {
      throw new Error(
        `${sectionName}.${feature} uses deprecated UI coverage fields`
      );
    }

    for (const test of coverage.logicTests) {
      if (!unitTests.has(test)) {
        throw new Error(
          `${sectionName}.${feature} references missing unit test ${test}`
        );
      }
    }
    const journeyTest = coverage.journeyTest;
    if (!uiTests.has(journeyTest)) {
      throw new Error(
        `${sectionName}.${feature} references missing UI journey ${journeyTest}`
      );
    }
    if (!journeyTest.includes("Journey")
        || journeyTest.includes("Discoverable")) {
      throw new Error(
        `${sectionName}.${feature} must use a dedicated Journey test`
      );
    }
    const previousClaim = claimedJourneyTests.get(journeyTest);
    if (previousClaim !== undefined) {
      throw new Error(
        `${sectionName}.${feature} reuses ${journeyTest} already claimed by ${previousClaim}`
      );
    }
    claimedJourneyTests.set(
      journeyTest,
      `${sectionName}.${feature}`
    );

    const journeySource = reachableFunctionSource(
      journeyTest,
      uiFunctionBodies
    );
    if (!journeySource.includes("XCTAssert")) {
      throw new Error(
        `${sectionName}.${feature} journey has no result assertion`
      );
    }
    if (!journeySource.includes("dismissPresentedWorkflow")
        && !journeySource.includes("cancelDocumentToolSelection")
        && !journeySource.includes("dismissPrivacyScan")) {
      throw new Error(
        `${sectionName}.${feature} journey has no cancel/re-entry evidence`
      );
    }
    if (!journeySource.includes("assertAppAlive")) {
      throw new Error(
        `${sectionName}.${feature} journey has no process-survival assertion`
      );
    }
  }
}

const modelSource = fs.readFileSync(modelPath, "utf8");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
if (manifest.schemaVersion !== 2) {
  throw new Error("Unsupported automation coverage schema");
}
const requiredJourneyEvidence = [
  "operationResult",
  "cancelReentry",
  "stateIsolation",
  "processSurvival"
];
if (!Array.isArray(manifest.requiredJourneyEvidence)
    || !sameMembers(
      manifest.requiredJourneyEvidence,
      requiredJourneyEvidence
    )) {
  throw new Error(
    "Automation coverage must require result, cancel/re-entry, state isolation, and process survival"
  );
}

const unitSource = swiftFiles(path.join(root, "PaperPathTests"))
  .map((file) => fs.readFileSync(file, "utf8"))
  .join("\n");
const uiSource = swiftFiles(path.join(root, "PaperPathUITests"))
  .map((file) => fs.readFileSync(file, "utf8"))
  .join("\n");
const uiFunctionBodies = functionBodies(uiSource);

validateSection({
  sectionName: "quickTasks",
  sourceCases: enumCases(modelSource, "PDFQuickTask"),
  entries: manifest.quickTasks,
  unitTests: testNames(unitSource),
  uiTests: testNames(uiSource),
  uiFunctionBodies
});
validateSection({
  sectionName: "documentTools",
  sourceCases: enumCases(modelSource, "DocumentTool"),
  entries: manifest.documentTools,
  unitTests: testNames(unitSource),
  uiTests: testNames(uiSource),
  uiFunctionBodies
});
validateSection({
  sectionName: "workflows",
  sourceCases: Object.keys(manifest.workflows ?? {}),
  entries: manifest.workflows ?? {},
  unitTests: testNames(unitSource),
  uiTests: testNames(uiSource),
  uiFunctionBodies
});

console.log(
  `Automation coverage OK: ${
    Object.keys(manifest.quickTasks).length
  } quick tasks, ${
    Object.keys(manifest.documentTools).length
  } document tools, ${
    Object.keys(manifest.workflows ?? {}).length
  } standalone workflows, ${
    claimedJourneyTests.size
  } unique result/cancel/re-entry/isolation/survival journeys.`
);
