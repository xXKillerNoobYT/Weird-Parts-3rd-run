import argparse
import json
from pathlib import Path


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def verify(source_before, source_after, receiver_before, receiver_after):
    receipts = [source_before, source_after, receiver_before, receiver_after]
    require(all(r.get('format') == 2 for r in receipts), 'Unsupported receipt format')
    require(len({r['run'] for r in receipts}) == 1, 'Run identifiers differ')
    require(source_before['localRole'] == source_after['localRole'] == 'sender', 'Receipt metadata differs')
    require(receiver_before['localRole'] == receiver_after['localRole'] == 'receiver', 'Receipt metadata differs')
    require(all(r['pinConfigured'] for r in receipts), 'Set synthetic PINs before collecting acceptance receipts')
    for before, after in [(source_before, source_after), (receiver_before, receiver_after)]:
        require(before['root'] == after['root'], 'Restart changed the storage root')
        require(before['expectedLocalDeviceId'] == after['expectedLocalDeviceId'], 'Receipt metadata differs')
        require(before['deviceIds'] == after['deviceIds'] == [before['expectedLocalDeviceId']], 'Local identity changed')
    fields = ['content', 'fixture', 'jobs', 'parts', 'categoryIds', 'typeIds', 'variantIds', 'photos']
    for field in fields:
        require(source_before[field] == source_after[field], f'Sender changed: {field}')
        require(source_before[field] == receiver_after[field], f'Receiver differs: {field}')
    require(receiver_before['fixture'] != receiver_after['fixture'], 'Receiver sentinel was not replaced')
    require(source_before['photos'], 'Photo evidence is missing')
    require(source_before['jobs'] and source_before['parts'], 'Shop evidence is missing')
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
