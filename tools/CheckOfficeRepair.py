"""Check real production Office artifacts against known corpus content contracts."""
import json
from collections import Counter
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile
from CompareOfficeRelease import normalized_numbers, package_text

root = Path(sys.argv[1])
report = json.loads((root / "report.json").read_text())
assert report["status"] == "completed"
cases = {item["id"]: item for item in report["results"]}
checks = []
ns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
      "s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def check(name, condition):
    checks.append({"check": name, "passed": bool(condition)})
    print(("PASS" if condition else "FAIL") + ": " + name)


def worksheet(name, number):
    with ZipFile(root / cases[name]["output"]) as archive:
        sheet = ET.fromstring(archive.read(f"xl/worksheets/sheet{number}.xml"))
    return [{
        cell.get("r"): cell.findtext("s:v", namespaces=ns)
        if cell.get("t") != "inlineStr"
        else "".join(t.text or "" for t in cell.findall(".//s:t", ns))
        for cell in row.findall("s:c", ns)
    } for row in sheet.findall(".//s:sheetData/s:row", ns)]


with ZipFile(root / cases["ComplexNumberedLists"]["output"]) as archive:
    document = ET.fromstring(archive.read("word/document.xml"))
paragraphs = []
for paragraph in document.findall(".//w:body/w:p", ns):
    text = "".join(t.text or "" for t in paragraph.findall(".//w:t", ns))
    indent = paragraph.find("w:pPr/w:ind", ns)
    paragraphs.append((text, int(indent.get("{" + ns["w"] + "}left", "0")) if indent is not None else 0))
texts = [text for text, _ in paragraphs]
for expected in ["a. 2-a", "b. 2-b", "c. 2-c", "1. Restarted to 1 from 5",
                 "10.Jump to new list at 10", "11.Now 11", "12.Carrying on @ 12",
                 "13.Carrying on @ 13"]:
    check(f"Word independent paragraph: {expected}", expected in texts)
indents = dict(paragraphs)
check("Word child indentation exceeds parent",
      indents.get("a. 2-a", 0) > indents.get("2. Entry #2, with children", 0))

rows = worksheet("ConditionalFormattingSamples", 1)
values = [[value for value in row.values()] for row in rows]
for label, value in [("Products1", "Cell value"), ("Products2", "Cell value (with formula)"),
                     ("Grades", "Top/bottom values"), ("Quarters", "Icon set"),
                     ("Customers2", "Formula-based")]:
    check(f"Excel aligned row: {label}", any(row == [label, value] for row in values))
check("Excel multiline value stays with Book tour",
      any(row == ["Book tour", "Top/bottom values\nAbove/below average"] for row in values))

pivot = [[value for value in row.values()] for row in worksheet("ExcelPivotTableSample", 2)]
for expected in [["Field1", "1-1月", "3-1月", "Total Result"],
                 ["a", "1", "", "1"], ["c", "", "3", "3"],
                 ["Total Result", "1", "3", "4"]]:
    check(f"Excel pivot column contract: {expected}", expected in pivot)

for name, case in cases.items():
    check(f"{name}: production export completed", not case.get("error") and bool(case.get("output")))
    notices = case["runtime"].get("contentNotices", [])
    check(f"{name}: content notices returned", bool(notices))
    check(f"{name}: saved notices survive model reload", case.get("persistedNoticesVerified") is True)
    input_numbers = Counter(normalized_numbers("\n".join(case["sourceTextByPage"])))
    output_numbers = Counter(normalized_numbers(package_text(root / case["output"])))
    check(f"{name}: all extracted numbers remain in the Office package",
          not input_numbers - output_numbers)
    with ZipFile(root / case["output"]) as archive:
        custom = archive.read("docProps/custom.xml").decode()
        check(f"{name}: notices travel with the file", "PaperPathContentNotices" in custom)
        if case["format"] != "excelWorkbook":
            continue
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        names = [sheet.get("name") for sheet in workbook.findall("s:sheets/s:sheet", ns)]
        check(f"{name}: every source page has a worksheet",
              names == [f"Page {index + 1}" for index in range(case["sourcePageCount"])])
        empty_pages = [i for i, text in enumerate(case["sourceTextByPage"]) if not text.strip()]
        warned = next((n["pageIndices"] for n in notices if n["kind"] == "pagesWithoutText"), [])
        check(f"{name}: empty-page notice matches actual source pages", warned == empty_pages)
        for index in empty_pages:
            sheet = ET.fromstring(archive.read(f"xl/worksheets/sheet{index + 1}.xml"))
            check(f"{name}: page {index + 1} empty sheet retained",
                  not sheet.findall(".//s:sheetData/s:row/s:c", ns))

(root / "repair-checks.json").write_text(json.dumps(checks, ensure_ascii=False, indent=2) + "\n")
assert all(item["passed"] for item in checks), "Production artifact checks failed; see repair-checks.json"
