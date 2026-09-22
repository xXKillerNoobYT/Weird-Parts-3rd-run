import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('receipts', Path(__file__).parents[2] / 'tool/verify_nearby_lan_receipts.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReceiptVerificationTest(unittest.TestCase):
    def records(self):
        source = dict(run='test', localRole='sender', root='/synthetic/source',
                      expectedLocalDeviceId='source-id', deviceIds=['source-id'],
                      pinConfigured=True, fixture='sender', jobs=[{'id': 'source-job'}],
                      parts=[{'id': 'source-part'}], categoryIds=['category'],
                      typeIds=['type'], variantIds=['variant'],
                      photos=[{'name': 'synthetic.png', 'sha256': 'source-hash'}])
        before = dict(source, localRole='receiver', root='/synthetic/receiver',
                      expectedLocalDeviceId='receiver-id', deviceIds=['receiver-id'], fixture='receiver')
        after = dict(before, fixture='sender')
        return copy.deepcopy([source, source, before, after])

    def test_persisted_replacement_passes(self):
        self.assertEqual(module.verify(*self.records())['result'], 'PASS')

    def test_changed_photo_or_receiver_identity_fails(self):
        for field, value in [('photos', [{'sha256': 'wrong'}]), ('deviceIds', ['source-id']), ('fixture', 'receiver')]:
            with self.subTest(field=field):
                records = self.records()
                records[3][field] = value
                with self.assertRaises(AssertionError):
                    module.verify(*records)

    def test_sender_mutation_and_missing_pin_fail(self):
        for field, value in [('jobs', []), ('pinConfigured', False)]:
            with self.subTest(field=field):
                records = self.records()
                records[1][field] = value
                with self.assertRaises(AssertionError):
                    module.verify(*records)


if __name__ == '__main__':
    unittest.main()
