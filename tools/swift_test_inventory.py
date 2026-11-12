"""Inventory XCTest methods in classes and extensions, ignoring comments/literals.

This is a bounded source inventory, not a Swift compiler. Runtime execution is
checked separately against xcresult identifiers.
"""
import re
from pathlib import Path

LITERAL = re.compile(r'(#+)?("""|")')


def code_only(source):
    chars = list(source)
    i = 0
    while i < len(source):
        start = i
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        elif source.startswith('/*', i):
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith('/*', i):
                    depth += 1
                    i += 2
                elif source.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
        else:
            literal = LITERAL.match(source, i)
            if literal:
                hashes = literal.group(1) or ''
                quote = literal.group(2)
                i += len(literal.group())
                close = quote + hashes
                while i < len(source):
                    if source.startswith('\\' + hashes, i):
                        i += len(hashes) + 2
                    elif source.startswith(close, i):
                        i += len(close)
                        break
                    else:
                        i += 1
            else:
                i += 1
                continue
        for offset in range(start, min(i, len(chars))):
            if chars[offset] != '\n':
                chars[offset] = ' '
    return ''.join(chars)


def inventory(directory):
    result = {}
    codes = {path: code_only(path.read_text()) for path in Path(directory).rglob('*.swift')}
    classes = {match.group(1) for code in codes.values()
               for match in re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b', code)}
    for path, code in codes.items():
        # Type ownership must end at its matching brace. In particular, an
        # extension after another class must not inherit that preceding class.
        depth = 0
        levels = []
        closing = {}
        stack = []
        for index, char in enumerate(code):
            levels.append(depth)
            if char == '{':
                stack.append(index)
                depth += 1
            elif char == '}':
                depth -= 1
                if stack:
                    closing[stack.pop()] = index
        for match in re.finditer(r'\b(class|extension)\s+(\w+)[^{]*\{', code):
            owner = match.group(2)
            if owner not in classes:
                continue
            opening = match.end() - 1
            end = closing.get(opening)
            if end is None:
                raise ValueError(f'Unclosed test type {owner} in {path}')
            for method in re.finditer(r'\bfunc\s+(test\w+)\s*\(', code[opening + 1:end]):
                offset = opening + 1 + method.start()
                if levels[offset] != levels[opening] + 1:
                    continue
                identifier = f'{owner}/{method.group(1)}()'
                if identifier in result:
                    raise ValueError(f'Duplicate XCTest declaration: {identifier}')
                result[identifier] = dict(path=str(path), line=code.count('\n', 0, offset) + 1)
    return result
