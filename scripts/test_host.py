"""The role this Mac plays for Checkmate, read from a marker file on the Mac itself, never from its name.

The test host builds, launches and drives Checkmate for tests. The build host only builds releases, imports
recordings and builds Stockfish. Any other Mac, the main Mac included, is neither and is refused both. Each host
carries ~/.config/checkmate/host-role holding one word, `test` or `build`; machine names stay out of the repository.

Python scripts import `require`; shell scripts run this file with a purpose (and `--role build` for build work) and
stop when it exits non-zero. The Swift and JavaScript guards read the same marker; scripts/test-run-gates.py checks it.
"""
import pathlib
import sys

ROLE_FILE = '.config/checkmate/host-role'
ROLES = ('test', 'build')


def host_role(home=None):
    """`test`, `build`, or None when this Mac has no marker. A marker naming any other role is refused outright."""
    marker = pathlib.Path(home if home is not None else pathlib.Path.home()) / ROLE_FILE
    try:
        role = marker.read_text().strip()
    except FileNotFoundError:
        return None
    if role not in ROLES:
        sys.exit(f'{marker} must hold one of {", ".join(ROLES)}, not {role!r}.')
    return role


def is_test_host(home=None):
    return host_role(home) == 'test'


def require(purpose='acceptance', role='test'):
    found = host_role()
    if found != role:
        sys.exit(f'Run {purpose} on the {role} host only; this Mac is '
                 + (f'the {found} host.' if found else f'neither (no ~/{ROLE_FILE}).'))


if __name__ == '__main__':
    arguments = sys.argv[1:]
    role = 'test'
    if arguments[:1] == ['--role']:
        if len(arguments) < 2 or arguments[1] not in ROLES:
            sys.exit(f'Usage: test_host.py [--role {"|".join(ROLES)}] [purpose]')
        role, arguments = arguments[1], arguments[2:]
    require(arguments[0] if arguments else 'acceptance', role)
