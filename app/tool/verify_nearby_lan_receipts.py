import argparse
import json
from pathlib import Path


def verify(source_before, source_after, receiver_before, receiver_after):
    receipts = [source_before, source_after, receiver_before, receiver_after]
    assert len({r['run'] for r in receipts}) == 1, 'Run identifiers differ'
    assert source_before['localRole'] == source_after['localRole'] == 'sender'
    assert receiver_before['localRole'] == receiver_after['localRole'] == 'receiver'
    assert all(r['pinConfigured'] for r in receipts), 'Set synthetic PINs before collecting acceptance receipts'
    for before, after in [(source_before, source_after), (receiver_before, receiver_after)]:
        assert before['root'] == after['root'], 'Restart changed the storage root'
        assert before['expectedLocalDeviceId'] == after['expectedLocalDeviceId']
        assert before['deviceIds'] == after['deviceIds'] == [before['expectedLocalDeviceId']], 'Local identity changed'
    fields = ['fixture', 'jobs', 'parts', 'categoryIds', 'typeIds', 'variantIds', 'photos']
    for field in fields:
        assert source_before[field] == source_after[field], f'Sender changed: {field}'
        assert source_before[field] == receiver_after[field], f'Receiver differs: {field}'
    assert receiver_before['fixture'] != receiver_after['fixture'], 'Receiver sentinel was not replaced'
    assert source_before['photos'], 'Photo evidence is missing'
    assert source_before['jobs'] and source_before['parts'], 'Shop evidence is missing'
    return {'result': 'PASS', 'run': source_before['run'],
            'verified': 'persisted shop replacement, unchanged sender content, photo hashes and receiver identity',
            'notVerified': 'house-LAN route, both-screen code comparison and PIN prompts require operator evidence'}


def main():
    parser = argparse.ArgumentParser()
    for name in ['source_before', 'source_after', 'receiver_before', 'receiver_after']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    records = [json.loads(getattr(args, name).read_text()) for name in
               ['source_before', 'source_after', 'receiver_before', 'receiver_after']]
    print(json.dumps(verify(*records), indent=2))


if __name__ == '__main__':
    main()
