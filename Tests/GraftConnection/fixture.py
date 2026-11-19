"""Stand-in for Graft's documented per-user status socket; accepts a status read and scoped changes for an assigned profile."""
import json
from pathlib import Path
import socket
import sys
import time

root = Path(sys.argv[1])
pool = root / 'pool'
pool.mkdir()
primary_uid = 'f731d554-6d0f-4a78-817e-b9bf2ae16f18'
backup_uid = '07e2ee11-8daf-4aa5-a70a-42c5be94aa45'
profiles = root / 'profiles'
for folder, uid in [('Claude', primary_uid), ('Claude-Studio', backup_uid)]:
    (profiles / folder).mkdir(parents=True)
    (profiles / folder / 'config.json').write_text(json.dumps({'lastKnownAccountUuid': uid.upper()}))
profile = '28DD0EAC-AED5-4C8F-BC67-5EC94716B961'
(root / 'shortcuts.json').write_text(json.dumps([{'id': profile, 'name': 'Studio', 'folder': 'Claude-Studio'}]))
(root / 'usage-sharing.json').write_text(json.dumps({'lenders': {'main': ['backup', 'main-alias', profile], profile: ['backup']}}))
# Junk in the opaque fields proves the reader never tries to decode them.
(pool / 'accounts.json').write_text(json.dumps([
    {'id': 'backup', 'email': 'second@example.org', 'accountUuid': backup_uid, 'sealed': {'invalid': True}},
    {'id': 'main-alias', 'email': 'first@example.org', 'accountUuid': primary_uid},
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
    def policy(member):
        value = {'profile': 'main', 'mode': 'only' if member else 'automatic'}
        if member:
            value['member'] = member
        return {'accountPolicy': value}

    # Start with an old helper. Then acknowledge each click except one deliberate failed clear.
    steps = [{}, {}, {}, {'recheckFable': 'backup'}, {},
             {}, policy(profile), {}, {}, {}, policy('main'), {}, policy(None), {}, policy(None)]
    for index, expected in enumerate(steps):
        if index == 5:
            status['exclusiveAccounts'] = {}
            status['selectableAccounts'] = {'main': ['main', profile]}
        client, _ = server.accept()
        with client, client.makefile('rb') as reader:
            incoming = json.loads(reader.readline())
            assert incoming == expected, 'unexpected command'
            if 'recheckFable' in incoming:
                members[1]['fableRecheckPending'] = True
            if 'accountPolicy' in incoming and index != 12:
                chosen = incoming['accountPolicy'].get('member')
                status['exclusiveAccounts'] = {'main': chosen} if chosen else {}
            client.sendall(json.dumps(status).encode() + b'\n')
