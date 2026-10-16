"""The role this Mac plays for Checkmate, read from a marker file on the Mac itself, never from its name.

The test host builds, launches and drives Checkmate for tests. The build host only builds releases, imports
recordings and builds Stockfish. Any other Mac, the main Mac included, is neither and is refused both. Each host
carries ~/.config/checkmate/host-role naming its roles: `test`, `build`, or both (`test build`) when one Mac does
both jobs. Machine names stay out of the repository.

Python scripts import `require`; shell scripts run this file with a purpose (and `--role build` for build work) and
stop when it exits non-zero. The Swift guards read the same marker; scripts/test-run-gates.py checks that they do.
"""
import pathlib
import sys

ROLE_FILE = '.config/checkmate/host-role'
ROLES = ('test', 'build')


def host_roles(home=None):
    """The roles this Mac's marker names, as a frozenset; empty when it has none. A marker that is empty, or names any
    other word, is refused outright rather than read as "no role"."""
    marker = pathlib.Path(home if home is not None else pathlib.Path.home()) / ROLE_FILE
    try:
        words = marker.read_text().split()
    except FileNotFoundError:
        return frozenset()
    if not words or any(word not in ROLES for word in words):
        sys.exit(f'{marker} must name {" and/or ".join(ROLES)}, not {" ".join(words)!r}.')
    return frozenset(words)


def is_test_host(home=None):
    return 'test' in host_roles(home)


def require(purpose='acceptance', role='test'):
    found = host_roles()
    if role not in found:
        sys.exit(f'Run {purpose} on the {role} host only; this Mac is '
                 + (f'the {" and ".join(sorted(found))} host.' if found else f'neither (no ~/{ROLE_FILE}).'))


if __name__ == '__main__':
    arguments = sys.argv[1:]
    role = 'test'
    if arguments[:1] == ['--role']:
        if len(arguments) < 2 or arguments[1] not in ROLES:
            sys.exit(f'Usage: test_host.py [--role {"|".join(ROLES)}] [purpose]')
        role, arguments = arguments[1], arguments[2:]
    require(arguments[0] if arguments else 'acceptance', role)
