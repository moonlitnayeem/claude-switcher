from datetime import datetime, timezone
import json
from pathlib import Path
import runpy
import tempfile

tool = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/check-graft-handoff.py'))
now = (datetime.now(timezone.utc) - tool['APPLE_EPOCH']).total_seconds()
base = {'model': 'claude-fable-5-2', 'at': now, 'from': 'main', 'servedBy': 'second', 'status': 200, 'passedOver': []}
settings = {'lenders': {'main': ['second']}, 'assignments': {'pinned': {'to': 'second'}}}
state = {'enabled': True, 'configured': True,
         'members': [{'id': 'main', 'limits': {'week': 1, 'weekReset': now + 3600}}],
         'recent': [base, {**base, 'session': 'pinned'}, {**base, 'session': 'unpinned'},
                    {**base, 'session': 'retried', 'passedOver': [{'id': 'main', 'reason': 'full'}]},
                    {**base, 'status': 429}, {**base, 'model': 'claude-test'}, {**base, 'at': now - 10}]}
cutoff = datetime.fromtimestamp(now + 978307200 - 1, timezone.utc)
counts = tool['summarize'](state, settings, cutoff)['Fable_5_2_results']
assert counts == {'backup_answer_without_session_attribution': 1, 'backup_answer_with_saved_chat_choice': 1,
                  'backup_answer_without_saved_choice_while_main_reports_full': 1,
                  'backup_answer_after_observed_primary_limit': 1, 'provider_error': 1}
state['members'][0]['limits']['weekReset'] = now - 1
counts = tool['summarize'](state, settings, cutoff)['Fable_5_2_results']
assert counts['backup_answer_without_observed_limit'] == 1
assert 'expected_account_Fable_5_2_answers' not in tool['summarize'](state, settings, cutoff)
verified = tool['summarize'](state, settings, cutoff, {'second': True})
assert verified['expected_account_is_a_configured_backup']
assert verified['expected_account_Fable_5_2_answers']['backup_answer_with_saved_chat_choice'] == 1
assert 'provider_error' not in verified['expected_account_Fable_5_2_answers']
unknown = tool['summarize'](state, settings, cutoff, {'second': None})
assert not unknown['all_backup_labels_available'] and not unknown['expected_account_is_a_configured_backup']
assert unknown['expected_account_Fable_5_2_answers'] == {}
unmatched = tool['summarize'](state, settings, cutoff, {'second': False})
assert unmatched['all_backup_labels_available'] and not unmatched['expected_account_is_a_configured_backup']
assert unmatched['expected_account_Fable_5_2_answers'] == {}

with tempfile.TemporaryDirectory() as folder:
    support = Path(folder)
    primary, backup = '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002'
    (support / 'Claude').mkdir()
    (support / 'Claude/config.json').write_text(json.dumps({'lastKnownAccountUuid': primary}))
    graft = support / 'ClaudeGraft'
    (graft / 'pool').mkdir(parents=True)
    entries = [{'id': key, 'accountUuid': account, 'email': email, 'sealed': {'unused': True}}
               for key, account, email in [('self-alias', primary, 'main@example.org'),
                                           ('second', backup, 'second@example.org'),
                                           ('backup-alias', backup, 'second@example.org')]]
    (graft / 'pool/accounts.json').write_text(json.dumps(entries))
    ids = [entry['id'] for entry in entries]
    aliases, matches = tool['identify_accounts'](graft, ids, 'main@example.org')
    assert aliases == {'self-alias': 'main', 'second': 'second', 'backup-alias': 'second'}
    setup = {'lenders': {'main': ids}, 'assignments': {
        'pinned-to-backup': {'to': 'second'}, 'changed': {'to': 'self-alias'},
        'changed-later': {'to': 'second', 'at': now + 5}}}
    events = [{**base, 'servedBy': 'self-alias'},
              {**base, 'servedBy': 'backup-alias', 'session': 'pinned-to-backup'},
              {**base, 'session': 'changed'}, {**base, 'session': 'changed-later'},
              {**base, 'session': 'auto', 'passedOver': [{'id': 'self-alias', 'reason': 'full'}]}]
    report = tool['summarize']({**state, 'recent': events}, setup, cutoff, matches, aliases)
    assert report['configured_backup_count'] == 1
    assert not report['expected_account_is_a_configured_backup']
    assert report['expected_account_Fable_5_2_answers'] == {}
    assert report['Fable_5_2_results'] == {'answered_by_main_or_previously_configured_account': 1,
        'backup_answer_with_saved_chat_choice': 1, 'backup_answer_with_changed_chat_choice': 2,
        'backup_answer_after_observed_primary_limit': 1}
    plain = tool['summarize']({**state, 'recent': events}, setup, cutoff, identity_available=False)
    assert plain['configured_backup_count'] is None
    assert plain['Fable_5_2_results'] == {'answered_by_configured_entry_with_unverified_identity': len(events)}
print('Post-install evidence distinguishes time cutoffs, target accounts, manual choices and provider limits')
