"""Reproducible public Office -> PDF -> PaperPath -> Office renderer checks."""

import argparse
from collections import Counter
from decimal import Decimal
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
import zipfile

import fitz
import numpy as np
from PIL import Image, ImageDraw
from skimage.metrics import structural_similarity


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def render(soffice, source, destination, profile):
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / (source.stem + ".pdf")
    if target.exists():
        raise FileExistsError(f"{target}: use a new evidence directory or --reuse-rendered")
    result = subprocess.run(
        [soffice, f"-env:UserInstallation={profile.as_uri()}",
         "--headless", "--norestore", "--nodefault", "--convert-to", "pdf",
         "--outdir", str(destination), str(source)],
        capture_output=True, text=True, timeout=150,
    )
    if result.returncode or not target.exists():
        raise RuntimeError(f"{source.name}: {result.stdout} {result.stderr}")
    return target, result.stdout + result.stderr


def pdf_text(path):
    with fitz.open(path) as document:
        return [page.get_text() for page in document]


def tokens(text):
    return re.findall(r"\w+", unicodedata.normalize("NFKC", text).casefold())


def recall(expected, actual):
    left, right = Counter(expected), Counter(actual)
    return round(sum((left & right).values()) / sum(left.values()), 4) if left else None


def normalized_numbers(text):
    numbers = re.findall(r"(?<!\w)[+-]?\d[\d,]*(?:\.\d+)?%?(?!\w)", text)
    result = []
    for number in numbers:
        suffix = "%" if number.endswith("%") else ""
        value = Decimal(number.rstrip("%").replace(",", ""))
        result.append(str(value.normalize()) + suffix)
    return result


def package_text(path):
    with zipfile.ZipFile(path) as archive:
        if path.suffix == ".xlsx":
            namespace = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
            shared = []
            if "xl/sharedStrings.xml" in archive.namelist():
                root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
                shared = ["".join(t.text or "" for t in si.findall(".//s:t", namespace))
                          for si in root.findall("s:si", namespace)]
            cells = []
            for name in archive.namelist():
                if re.search(r"xl/worksheets/sheet\d+\.xml$", name):
                    root = ET.fromstring(archive.read(name))
                    for cell in root.findall(".//s:sheetData/s:row/s:c", namespace):
                        value = cell.findtext("s:v", default="", namespaces=namespace)
                        if cell.get("t") == "s":
                            cells.append(shared[int(value)])
                        elif cell.get("t") == "inlineStr":
                            cells.append("".join(t.text or "" for t in cell.findall(".//s:t", namespace)))
                        else:
                            cells.append(value)
            return "\n".join(cells)
        texts = []
        for name in archive.namelist():
            if (name == "word/document.xml"
                    or re.search(r"word/(?:header|footer)\d+\.xml$", name)
                    or re.search(r"ppt/slides/slide\d+\.xml$", name)):
                root = ET.fromstring(archive.read(name))
                texts.extend(element.text or "" for element in root.iter()
                             if element.tag.rsplit("}", 1)[-1] == "t")
        return "\n".join(texts)


def structure(path):
    with zipfile.ZipFile(path) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise RuntimeError(f"Bad ZIP entry: {corrupt}")
        names = archive.namelist()
        values = Counter()
        namespace = {
            "t": "textNodes", "tbl": "tables", "f": "formulas",
            "pic": "pictures", "sp": "shapes", "drawing": "drawings",
            "mergeCell": "mergedCells", "conditionalFormatting": "conditionalFormats",
        }
        for name in names:
            if name.endswith(".xml"):
                root = ET.fromstring(archive.read(name))
                if "/worksheets/" in name:
                    values["worksheets"] += 1
                if re.search(r"/slides/slide\d+\.xml$", name):
                    values["slides"] += 1
                for element in root.iter():
                    local = element.tag.rsplit("}", 1)[-1]
                    if local in namespace:
                        values[namespace[local]] += 1
        values["mediaFiles"] = sum("/media/" in name for name in names)
        values["chartFiles"] = sum(bool(re.search(r"/charts/chart\d+\.xml$", name)) for name in names)
        return dict(values)


def page_image(page, width=700):
    pixmap = page.get_pixmap(matrix=fitz.Matrix(width / page.rect.width, width / page.rect.width),
                            colorspace=fitz.csRGB, alpha=False)
    return Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)


def visuals(reference, output, directory):
    directory.mkdir(parents=True, exist_ok=True)
    comparisons = []
    with fitz.open(reference) as source, fitz.open(output) as result:
        for index in range(min(len(source), len(result))):
            a = page_image(source[index])
            b = page_image(result[index])
            same_size = (
                abs(source[index].rect.width - result[index].rect.width) < 1
                and abs(source[index].rect.height - result[index].rect.height) < 1
            )
            normalized = b.resize(a.size)
            similarity = float(structural_similarity(
                np.asarray(a), np.asarray(normalized), channel_axis=2, data_range=255
            ))
            comparisons.append({
                "page": index + 1, "samePhysicalSize": same_size,
                "normalizedSSIM": round(similarity, 4),
                "sourceSize": list(source[index].rect[2:]),
                "outputSize": list(result[index].rect[2:]),
            })
            # Keep the first three and low-similarity pages for direct visual inspection.
            if index < 3 or (similarity < 0.9 and index < 12):
                height = max(a.height, b.height)
                canvas = Image.new("RGB", (a.width + b.width + 30, height + 42), "white")
                canvas.paste(a, (0, 42))
                canvas.paste(b, (a.width + 30, 42))
                draw = ImageDraw.Draw(canvas)
                draw.text((10, 12), f"Reference PDF | page {index + 1}", fill="black")
                draw.text((a.width + 40, 12), f"PaperPath output | SSIM {similarity:.3f}", fill="black")
                canvas.save(directory / f"page-{index + 1:02d}.png")
    return comparisons


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["reference", "compare"])
    parser.add_argument("--root", type=Path, default=Path("design/office-release-2026-09-14"))
    parser.add_argument("--soffice", required=True)
    parser.add_argument("--reuse-rendered", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    profile = Path("/tmp/PaperPath-OfficeRelease-20260914/lo-profile").resolve()
    manifest = json.loads((root / "source-manifest.json").read_text())
    formats = {"docx": "wordDocument", "xlsx": "excelWorkbook", "pptx": "powerPointPresentation"}
    if args.mode == "reference":
        cases = []
        log = []
        for item in manifest["documents"]:
            original = root / item["path"]
            pdf, message = render(args.soffice, original, root / "reference", profile)
            pages = pdf_text(pdf)
            cases.append({"id": original.stem, "input": pdf.name,
                          "format": formats[original.suffix[1:]]})
            log.append({
                "id": original.stem, "pages": len(pages),
                "pdfSHA256": hashlib.sha256(pdf.read_bytes()).hexdigest(),
                "originalStructure": structure(original), "rendererOutput": message,
            })
            print(f"REFERENCE {original.name}: {len(pages)} pages", flush=True)
        dump(root / "cases.json", cases)
        dump(root / "reference-report.json", log)
        return

    report = json.loads((root / "report.json").read_text())
    output_reports = []
    for case in report["results"]:
        if not case.get("output"):
            output_reports.append({"id": case["id"], "conversionError": case.get("error")})
            continue
        original = next(root / item["path"] for item in manifest["documents"]
                        if Path(item["path"]).stem == case["id"])
        exported = root / case["output"]
        try:
            if args.reuse_rendered:
                output_pdf = root / "roundtrip" / (exported.stem + ".pdf")
                if not output_pdf.is_file():
                    raise FileNotFoundError(output_pdf)
                message = "Reused previously rendered PDF; no source or output changes."
            else:
                output_pdf, message = render(args.soffice, exported, root / "roundtrip", profile)
            reference = root / "reference" / (case["id"] + ".pdf")
            source_pages, output_pages = pdf_text(reference), pdf_text(output_pdf)
            source_text, output_text = "\n".join(source_pages), "\n".join(output_pages)
            number_pattern = r"(?<!\w)[+-]?\d[\d,]*(?:\.\d+)?%?(?!\w)"
            source_tokens, output_tokens = tokens(source_text), tokens(output_text)
            source_numbers = re.findall(number_pattern, source_text)
            output_numbers = re.findall(number_pattern, output_text)
            source_number_count, output_number_count = Counter(source_numbers), Counter(output_numbers)
            native = package_text(exported)
            pdfkit_text = "\n".join(case["sourceTextByPage"])
            metrics = {
                "id": case["id"], "sourcePages": len(source_pages), "outputPages": len(output_pages),
                "sourceTokens": len(source_tokens), "outputTokens": len(output_tokens),
                "textTokenRecall": recall(source_tokens, output_tokens),
                "orderedTokenSimilarity": round(difflib.SequenceMatcher(
                    None, source_tokens, output_tokens, autojunk=False
                ).ratio(), 4),
                "numericTokenRecall": recall(source_numbers, output_numbers),
                "normalizedNumericRecall": recall(normalized_numbers(source_text), normalized_numbers(output_text)),
                "packageTextTokenRecall": recall(source_tokens, tokens(native)),
                "packageNormalizedNumericRecall": recall(normalized_numbers(source_text), normalized_numbers(native)),
                "pdfKitInputTextTokenRecall": recall(source_tokens, tokens(pdfkit_text)),
                "packageVsPDFKitTokenRecall": recall(tokens(pdfkit_text), tokens(native)),
                "pdfKitEmptyPages": [i + 1 for i, text in enumerate(case["sourceTextByPage"]) if not text.strip()],
                "missingNumericTokens": list((source_number_count - output_number_count).elements())[:80],
                "missingTokens": list((Counter(source_tokens) - Counter(output_tokens)).elements())[:80],
                "originalStructure": structure(original), "outputStructure": structure(exported),
                "visuals": visuals(reference, output_pdf, root / "comparisons" / case["id"]),
                "rendererOutput": message,
            }
            (root / "roundtrip" / (case["id"] + "-reference.txt")).write_text(source_text)
            (root / "roundtrip" / (case["id"] + "-output.txt")).write_text(output_text)
            (root / "roundtrip" / (case["id"] + "-package.txt")).write_text(native)
            output_reports.append(metrics)
            print(f"COMPARE {case['id']}: pages {len(source_pages)} -> {len(output_pages)}, "
                  f"text {metrics['textTokenRecall']}, numeric {metrics['numericTokenRecall']}", flush=True)
        except Exception as error:
            output_reports.append({"id": case["id"], "renderError": str(error)})
            print(f"FAILED {case['id']}: {error}", flush=True)
        dump(root / "comparison-report.json", output_reports)


if __name__ == "__main__":
    main()
