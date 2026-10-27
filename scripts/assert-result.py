"""Print a scenario's JSON result and exit 1 unless it passed, printing the fields that failed.

  assert-result.py FILE [FIELD ...]

Prints the result as one JSON line: whole, or only the named fields in that order. FIELD must be present; FIELD? may be
absent (printed as null); #FIELD prints the length of a list. A missing or unreadable file fails like a failed result.
"""
import json
import sys


def shown(result: dict, fields: list) -> dict:
    if not fields:
        return result
    summary = {}
    for field in fields:
        if field.startswith('#'):
            summary[field[1:]] = len(result[field[1:]])
        elif field.endswith('?'):
            summary[field[:-1]] = result.get(field[:-1])
        else:
            summary[field] = result[field]
    return summary


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    path, fields = sys.argv[1], sys.argv[2:]
    with open(path) as file:
        result = json.load(file)
    if not isinstance(result, dict):
        print(f'{path} is not a JSON object', file=sys.stderr)
        return 1
    print(json.dumps(shown(result, fields)))
    if result.get('passed'):
        return 0
    failing = {key: value for key, value in result.items() if value is False or (key == 'failures' and value)}
    print(f"{path} did not pass: {json.dumps({'passed': result.get('passed'), **failing})}", file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
