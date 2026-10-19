import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

SPEC = importlib.util.spec_from_file_location('godaddy_hook', Path(__file__).resolve().parents[1] / 'certbot-godaddy.py')
hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hook)
VALUE = 'a' * 43


class MemoryAPI:
    def __init__(self, records=None):
        self.items = list(records or [])
        self.deleted = []

    def records(self):
        return [dict(r) for r in self.items if r['name'] == hook.RECORD_NAME and r['type'] == 'TXT']

    def create(self, value):
        self.items.append({'recordId': 'created', 'name': hook.RECORD_NAME, 'type': 'TXT', 'data': value})
        return 'created'

    def delete_owned(self, record_id, value):
        return hook.GoDaddy.delete_owned(self, record_id, value)

    def request(self, method, suffix):
        self.deleted.append(suffix[1:])
        self.items = [r for r in self.items if r['recordId'] != suffix[1:]]


class DNSHookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_only_expected_domain_and_dns_validation_value_are_allowed(self):
        self.assertEqual(hook.challenge_value({'CERTBOT_DOMAIN': 'kushui.shop', 'CERTBOT_VALIDATION': VALUE}), VALUE)
        for domain, value in [('other.shop', VALUE), ('*.kushui.shop', VALUE), ('kushui.shop', '../bad')]:
            with self.assertRaises(hook.HookError):
                hook.challenge_value({'CERTBOT_DOMAIN': domain, 'CERTBOT_VALIDATION': value})

    def test_token_must_be_private_and_not_a_symlink(self):
        token = self.root / 'pat'
        token.write_text('test-token-' + 'x' * 40)
        token.chmod(0o600)
        self.assertTrue(hook.load_token(token).startswith('test-token-'))
        token.chmod(0o644)
        with self.assertRaises(hook.HookError):
            hook.load_token(token)
        token.chmod(0o600)
        link = self.root / 'link'
        link.symlink_to(token)
        with self.assertRaises(OSError):
            hook.load_token(link)

    def test_api_error_never_contains_token_or_response_body(self):
        token = 'test-secret-' + 'x' * 40
        api = hook.GoDaddy(token)
        error = urllib.error.HTTPError(hook.API, 403, 'refused', {}, io.BytesIO(token.encode()))
        with patch.object(api.opener, 'open', side_effect=error):
            with self.assertRaises(hook.HookError) as raised:
                api.records()
        self.assertIn('403', str(raised.exception))
        self.assertNotIn(token, str(raised.exception))

    def test_list_ignores_unrelated_records_even_if_api_filter_is_ignored(self):
        api = hook.GoDaddy('unused-token')
        with patch.object(api, 'request', return_value={'items': [
            {'type': 'A', 'name': '@', 'data': '38.127.133.6'},
            {'type': 'TXT', 'name': '_dmarc', 'data': 'retain'},
            {'type': 'TXT', 'name': hook.RECORD_NAME, 'data': 'keep'},
        ]}):
            self.assertEqual(len(api.records()), 1)

    def test_success_and_cleanup_preserve_old_challenge_and_business_records(self):
        before = [
            {'recordId': 'old', 'type': 'TXT', 'name': hook.RECORD_NAME, 'data': 'old-verification'},
            {'recordId': 'apex', 'type': 'A', 'name': '@', 'data': '38.127.133.6'},
        ]
        api = MemoryAPI(before)
        challenge = hook.Challenge(api, self.root / 'state', visible=lambda value: True)
        challenge.auth(VALUE, settle=0)
        self.assertEqual(len(api.items), 3)
        self.assertEqual(challenge.path(VALUE).stat().st_mode & 0o777, 0o600)
        challenge.cleanup(VALUE)
        self.assertEqual(api.items, before)
        self.assertEqual(api.deleted, ['created'])

    def test_failed_dns_verification_cleans_only_created_record(self):
        api = MemoryAPI()
        challenge = hook.Challenge(api, self.root / 'state', visible=lambda value: False)
        with self.assertRaises(hook.HookError):
            challenge.auth(VALUE, timeout=0, settle=0)
        self.assertEqual(api.items, [])
        self.assertFalse(challenge.path(VALUE).exists())

    def test_preexisting_matching_value_is_never_deleted(self):
        previous = {'recordId': 'preexisting', 'type': 'TXT', 'name': hook.RECORD_NAME, 'data': VALUE}
        api = MemoryAPI([previous])
        challenge = hook.Challenge(api, self.root / 'state', visible=lambda value: True)
        challenge.auth(VALUE, settle=0)
        challenge.cleanup(VALUE)
        self.assertEqual(api.items, [previous])
        self.assertEqual(api.deleted, [])

    def test_changed_record_is_not_deleted_and_state_is_retained(self):
        api = MemoryAPI()
        challenge = hook.Challenge(api, self.root / 'state', visible=lambda value: True)
        challenge.auth(VALUE, settle=0)
        api.items[0]['data'] = 'changed-by-another-operation'
        with self.assertRaises(hook.HookError):
            challenge.cleanup(VALUE)
        self.assertEqual(len(api.items), 1)
        self.assertTrue(challenge.path(VALUE).exists())

    def test_cleanup_recovers_unknown_post_outcome_by_exact_value(self):
        api = MemoryAPI()
        challenge = hook.Challenge(api, self.root / 'state')
        challenge.save(VALUE, {'domain': hook.DOMAIN, 'value': VALUE, 'owned': True, 'recordId': None})
        api.create(VALUE)
        challenge.cleanup(VALUE)
        self.assertEqual(api.items, [])
        self.assertFalse(challenge.path(VALUE).exists())

    def test_create_timeout_recovers_result_without_duplicate_post(self):
        api = hook.GoDaddy('unused-token')
        with patch.object(api, 'request', side_effect=hook.HookError('timeout')) as request:
            with patch.object(api, 'records', return_value=[{'recordId': 'recovered', 'data': VALUE}]):
                self.assertEqual(api.create(VALUE), 'recovered')
        self.assertEqual(request.call_count, 1)


if __name__ == '__main__':
    unittest.main()
