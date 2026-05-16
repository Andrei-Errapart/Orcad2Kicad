"""S-expression parser and tree helpers for KiCad files."""


def tokenize(text):
    """Tokenize an S-expression string into a flat list of tokens."""
    tokens = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '(':
            tokens.append('(')
            i += 1
        elif c == ')':
            tokens.append(')')
            i += 1
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == '\\':
                    j += 1
                j += 1
            tokens.append(text[i:j + 1])
            i = j + 1
        elif c in ' \t\n\r':
            i += 1
        else:
            j = i
            while j < n and text[j] not in '() \t\n\r"':
                j += 1
            tokens.append(text[i:j])
            i = j
    return tokens


def parse_sexpr(tokens, idx=0):
    """Parse tokens into nested lists. Returns (parsed, next_index)."""
    if tokens[idx] == '(':
        lst = []
        idx += 1
        while tokens[idx] != ')':
            item, idx = parse_sexpr(tokens, idx)
            lst.append(item)
        return lst, idx + 1
    else:
        return tokens[idx], idx + 1


def parse(text):
    """Parse a KiCad file's text into an S-expression tree."""
    tokens = tokenize(text)
    results = []
    idx = 0
    while idx < len(tokens):
        item, idx = parse_sexpr(tokens, idx)
        results.append(item)
    return results[0] if len(results) == 1 else results


def find_first(tree, tag):
    """Find the first direct child list starting with tag."""
    if isinstance(tree, list):
        for child in tree[1:]:
            if isinstance(child, list) and len(child) > 0 and child[0] == tag:
                return child
    return None


def find_all(tree, tag):
    """Find all direct child lists starting with tag."""
    results = []
    if isinstance(tree, list):
        for child in tree[1:]:
            if isinstance(child, list) and len(child) > 0 and child[0] == tag:
                results.append(child)
    return results


def strip_quotes(s):
    if isinstance(s, str) and s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    return s


def to_float(s):
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0
