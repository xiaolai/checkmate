"""The machine that may build, launch and drive Checkmate for tests: never the main Mac, and not build-host, which only
builds releases, imports recordings and builds Stockfish.

Every test script checks this one list, by lowercased host name. Python scripts import `require`; shell
scripts run this file with a purpose and stop when it exits non-zero.
"""
import socket
import sys

TEST_HOSTS = ('test-host',)


def is_test_host(name=None):
    host = (name if name is not None else socket.gethostname()).lower()
    return any(test_host in host for test_host in TEST_HOSTS)


def require(purpose='acceptance'):
    if not is_test_host():
        sys.exit(f'Run {purpose} on a test host only ({", ".join(TEST_HOSTS)}), not {socket.gethostname()}.')


if __name__ == '__main__':
    require(sys.argv[1] if len(sys.argv) > 1 else 'acceptance')
