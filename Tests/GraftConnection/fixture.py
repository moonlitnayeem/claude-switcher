"""Stand-in for Graft's documented per-user status socket; accepts a status read and one scoped action."""
import json
from pathlib import Path
import socket
import sys
import time

root = Path(sys.argv[1])
pool = root / 'pool'
pool.mkdir()
profile = '28DD0EAC-AED5-4C8F-BC67-5EC94716B961'
(root / 'shortcuts.json').write_text(json.dumps([{'id': profile, 'name': 'Studio'}]))
(root / 'usage-sharing.json').write_text(json.dumps({'lenders': {'main': ['backup'], profile: []}}))
# Junk in the opaque fields proves the reader never tries to decode them.
(pool / 'accounts.json').write_text(json.dumps([
    {'id': 'backup', 'email': 'second@example.org', 'sealed': {'invalid': True}},
    {'id': 'unused', 'email': 'unused@example.net', 'sealed': [True]}]))
now = time.time() - 978307200
limits = {'fiveHour': 0.1, 'week': 0.3, 'weekReset': now + 3600, 'observed': now, 'fableRefusedUntil': now + 1800}
members = [{'id': 'main', 'limits': {**limits, 'week': 1}, 'served': 0, 'tokenRefused': False},
           {'id': 'backup', 'limits': limits, 'served': 1, 'lastServed': now, 'tokenRefused': False}]
status = {'binary': 'fixture', 'pid': 1, 'started': now, 'enabled': True, 'configured': True,
          'members': members, 'openExchanges': 0, 'sessions': [], 'recent': [
              {'at': now, 'from': 'main', 'servedBy': 'backup', 'status': 200, 'passedOver': [],
               'model': 'claude-fable-5-2'}]}
with socket.socket(socket.AF_UNIX) as server:
    server.bind(str(pool / 'relay.sock'))
    server.listen(1)
    server.settimeout(10)
    for expected in [{}, {}, {}, {'recheckFable': 'backup'}]:
        client, _ = server.accept()
        with client, client.makefile('rb') as reader:
            incoming = json.loads(reader.readline())
            assert incoming == expected, 'unexpected command'
            if 'recheckFable' in incoming:
                members[1]['fableRecheckPending'] = True
            client.sendall(json.dumps(status).encode() + b'\n')
