"""Independent DOCX structure/text oracle; stdlib XML/ZIP plus pypdf, offline."""
from collections import Counter
from pathlib import PurePosixPath
import re
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
from pypdf import PdfReader

W = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
TYPES = '{http://schemas.openxmlformats.org/package/2006/content-types}'


def words(text):
    return Counter(re.findall(r'[^\W_]+', unicodedata.normalize('NFKC', text).replace('\u00ad', '').casefold()))


def audit_docx(path, original):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist(); names = [item.filename for item in entries]
        assert names and len(names) == len(set(names)), 'DOCX has empty or duplicate ZIP entries'
        assert sum(item.file_size for item in entries) <= 128 * 1024 * 1024, 'DOCX expands beyond the audit limit'
        for name in names:
            assert not PurePosixPath(name).is_absolute() and '..' not in PurePosixPath(name).parts, 'DOCX contains an unsafe path'
        assert archive.testzip() is None, 'DOCX ZIP checksums are invalid'
        assert '[Content_Types].xml' in names and 'word/document.xml' in names, 'DOCX is missing its main document'
        types = ET.fromstring(archive.read('[Content_Types].xml'))
        assert any(node.get('PartName') == '/word/document.xml' and node.get('ContentType') ==
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'
            for node in types.findall(TYPES + 'Override')), 'DOCX has the wrong main content type'
        document = ET.fromstring(archive.read('word/document.xml'))
        assert document.tag == W + 'document', 'DOCX has the wrong document root'
        paragraphs = []
        def inline(node, top=False):
            if node.tag == W + 'p' and not top: return ''
            if node.tag == W + 't': return node.text or ''
            if node.tag in {W + 'tab', W + 'br'}: return ' '
            return ''.join(inline(child) for child in node)
        numbering = Counter()
        for paragraph in document.iter(W + 'p'):
            text = inline(paragraph, top=True)
            number = paragraph.find('./' + W + 'pPr/' + W + 'numPr/' + W + 'numId')
            if number is not None:
                number_id = number.get(W + 'val'); numbering[number_id] += 1
                text = str(numbering[number_id]) + ' ' + text
            paragraphs.append(text)
        output = words('\n'.join(paragraphs))
        source = words('\n'.join(page.extract_text() or '' for page in PdfReader(original, strict=True).pages))
        assert source, 'Word source has no native text to verify'
        missing = source - output
        assert not missing, 'Word output lost original words or numbers: ' + repr(dict(missing.most_common(12)))
        return dict(validDocxStructure=True, allNativeWordsAndNumbersPreserved=True,
                    sourceWordCount=sum(source.values()), outputWordCount=sum(output.values()), paragraphCount=len(paragraphs))
