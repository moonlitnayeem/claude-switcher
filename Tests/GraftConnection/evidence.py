from datetime import datetime, timezone
from pathlib import Path
import runpy

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
print('Post-install evidence distinguishes time cutoffs, target accounts, manual choices and provider limits')
