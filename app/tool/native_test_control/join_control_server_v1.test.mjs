import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, verify } from 'node:crypto';
import { createJoinControlServer, isResponseConnected } from './join_control_server_v1.mjs';

const windows = generateKeyPairSync('ed25519');
const mac = generateKeyPairSync('ed25519');
const stranger = generateKeyPairSync('ed25519');
const channelId = Buffer.alloc(16, 9).toString('base64url');
const requestPrefix = 'wired-parts/j60-test-control/request/v1\n';
const responsePrefix = 'wired-parts/j60-test-control/response/v1\n';
const peerAddress = '192.0.2.10';
const encode = value => Buffer.from(value).toString('base64url');
const canonical = value => Array.isArray(value) ? `[${value.map(canonical).join(',')}]` : value !== null && typeof value === 'object' ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}` : JSON.stringify(value);
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

function fixture(t, options = {}) {
  let clock = 1000000;
  let sequence = 0;
  const config = { channelId, peerAddress, windowsPublicKeyDer: windows.publicKey.export({ format: 'der', type: 'spki' }).toString('base64url'), privateKey: mac.privateKey, now: () => clock, ...options };
  const lane = createJoinControlServer(config);
  t.after(() => lane.stop());
  function request(change = {}, raw, signingKey = windows.privateKey) {
    const payload = { version: 1, run: config.run ?? 'j60-join-v10', channelId, op: 'echo', nonce: Buffer.alloc(16, ++sequence).toString('base64url'), expiresAtMillis: clock + 10000, args: { challenge: 'hello' }, ...change };
    raw ??= canonical(payload);
    return { method: 'POST', path: '/join-control', peerAddress, body: JSON.stringify({ payload: encode(raw), signature: sign(null, Buffer.from(requestPrefix + raw), signingKey).toString('base64url') }) };
  }
  async function send(req = request(), transport = {}) {
    const flushed = [];
    const reply = await lane.handle(req, { flush: async response => { flushed.push(response); }, ...transport });
    return { reply, flushed, data: reply.statusCode === 200 ? read(reply, req, config.run) : undefined };
  }
  return { lane, config, request, send, advance: milliseconds => { clock += milliseconds; } };
}

function read(reply, request, run = 'j60-join-v10') {
  assert.equal(reply.statusCode, 200);
  assert.ok(Buffer.byteLength(reply.body) <= 16384);
  const envelope = JSON.parse(reply.body);
  assert.deepEqual(Object.keys(envelope).sort(), ['payload', 'signature']);
  const raw = Buffer.from(envelope.payload, 'base64url').toString('utf8');
  assert.equal(verify(null, Buffer.from(responsePrefix + raw), mac.publicKey, Buffer.from(envelope.signature, 'base64url')), true);
  const payload = JSON.parse(raw);
  assert.equal(raw, canonical(payload));
  assert.deepEqual(Object.keys(payload).sort(), ['channelId', 'nonce', 'ok', 'requestSha256', 'result', 'run', 'version']);
  assert.equal(payload.version, 1);
  assert.equal(payload.run, run);
  assert.equal(payload.channelId, channelId);
  const requestRaw = Buffer.from(JSON.parse(request.body).payload, 'base64url');
  assert.equal(payload.nonce, JSON.parse(requestRaw).nonce);
  assert.equal(payload.requestSha256, createHash('sha256').update(requestRaw).digest('hex'));
  return payload;
}

async function refused(f, req) {
  const actual = await f.send(req);
  assert.deepEqual(actual.reply, { statusCode: 403, body: '{"error":"refused"}' });
  assert.deepEqual(actual.flushed, [actual.reply]);
}

async function failure(f, req, error) {
  const actual = await f.send(req);
  assert.equal(actual.data.ok, false);
  assert.deepEqual(actual.data.result, { error });
  return actual;
}

test('signed echo authenticates peer, binds response and keeps lane fresh', async t => {
  const f = fixture(t);
  const actual = await f.send();
  assert.equal(actual.data.ok, true);
  assert.deepEqual(actual.data.result, { challenge: 'hello' });
  assert.deepEqual(actual.flushed, [actual.reply]);
  assert.equal(f.lane.state, 'fresh');
  const mapped = f.request({ args: { challenge: 'mapped' } });
  mapped.peerAddress = '::ffff:192.0.2.10';
  assert.deepEqual((await f.send(mapped)).data.result, { challenge: 'mapped' });
});

test('only explicit admitted runs enter the configured signed lane', async t => {
  const legacy = fixture(t);
  for (const run of ['', null, 'j61-created-v1', 'j61-created-v2', 'j61-created-v3', 'j61-created-v4', 'j61-created-v5', 'j61-created-v6', 'j61-created-v7', 'j61-created-v8', 'j61-created-v9', 'j61-created-v13', 'j61-created-v15', 'company-j61-created-v14', 'j60-join-v10 ', ['j61-created-v14']]) {
    assert.throws(() => createJoinControlServer({ ...legacy.config, run }), /Invalid local configuration/);
  }
  for (const run of ['j60-join-v10', 'j61-created-v14']) {
    const f = fixture(t, { run });
    assert.deepEqual((await f.send()).data.result, { challenge: 'hello' });
    let calls = 0;
    f.lane.arm(async () => { calls++; return { senderGrant: {}, afterReply: async () => {} }; });
    const otherRun = run === 'j60-join-v10' ? 'j61-created-v14' : 'j60-join-v10';
    await failure(f, f.request({ run: otherRun, op: 'compare', args: { sealedObservation: {} } }), 'refused');
    assert.equal(calls, 0);
    assert.equal(f.lane.state, 'armed');
    assert.deepEqual((await f.send(f.request({ op: 'compare', args: { sealedObservation: {} } }))).data.result, { senderGrant: {} });
    assert.equal(calls, 1);
  }
});

test('wrong signer and mutated signatures fail authentication', async t => {
  const f = fixture(t);
  await refused(f, f.request({}, undefined, stranger.privateKey));
  const req = f.request();
  const envelope = JSON.parse(req.body);
  envelope.signature = Buffer.alloc(64).toString('base64url');
  req.body = JSON.stringify(envelope);
  await refused(f, req);
});

test('wrong transport metadata never enters local handler', async t => {
  const f = fixture(t);
  let calls = 0;
  f.lane.arm(async () => { calls += 1; return { senderGrant: { sealed: 'grant' }, afterReply: async () => {} }; });
  for (const patch of [{ peerAddress: '192.0.2.11' }, { peerAddress: undefined }, { method: 'GET' }, { path: '/other' }]) {
    await refused(f, { ...f.request({ op: 'compare', args: { sealedObservation: {} } }), ...patch });
  }
  assert.equal(calls, 0);
  assert.deepEqual((await f.send(f.request({ op: 'compare', args: { sealedObservation: {} } }))).data.result, { senderGrant: { sealed: 'grant' } });
  assert.equal(calls, 1);
});

for (const [name, changes, expected] of [
  ['run', { run: 'another-run' }, 'refused'],
  ['channel', { channelId: Buffer.alloc(16, 8).toString('base64url') }, 'refused'],
  ['version', { version: 2 }, 'refused'],
  ['extra field', { extra: true }, 'refused'],
  ['unsupported operation', { op: 'eval' }, 'refused'],
  ['expired deadline', { expiresAtMillis: 1000000 }, 'expired'],
  ['excess deadline', { expiresAtMillis: 1010001 }, 'expired'],
  ['fractional deadline', { expiresAtMillis: 1000000.5 }, 'expired'],
  ['echo argument extra', { args: { challenge: 'ok', other: true } }, 'refused'],
  ['echo challenge size', { args: { challenge: 'a'.repeat(65) } }, 'refused'],
  ['compare before arming', { op: 'compare', args: { sealedObservation: {} } }, 'not-ready'],
]) {
  test(`signed ${name} rejection`, async t => { const f = fixture(t); await failure(f, f.request(changes), expected); });
}

test('nonce length and encoding are checked before admission', async t => {
  const f = fixture(t);
  for (const nonce of ['', 'a', Buffer.alloc(15).toString('base64url'), `${Buffer.alloc(16).toString('base64url')}=`]) await refused(f, f.request({ nonce }));
});

test('canonical JSON rejects whitespace, unsorted keys and duplicate keys', async t => {
  const f = fixture(t);
  const good = f.request();
  const raw = Buffer.from(JSON.parse(good.body).payload, 'base64url').toString();
  for (const invalid of [` ${raw}`, JSON.stringify(Object.fromEntries(Object.entries(JSON.parse(raw)).reverse())), raw.replace('"version":1', '"version":1,"version":1')]) await refused(f, f.request({}, invalid));
  assert.deepEqual((await f.send(good)).data.result, { challenge: 'hello' });
});

test('nested lexical ordering accepts numeric-looking keys and rejects unsorted nested keys', async t => {
  const f = fixture(t);
  f.lane.arm(async sealed => ({ senderGrant: { sealed }, afterReply: async () => {} }));
  const req = f.request({ op: 'compare', args: { sealedObservation: { 2: 'b', 10: 'a' } } });
  assert.deepEqual((await f.send(req)).data.result, { senderGrant: { sealed: { 2: 'b', 10: 'a' } } });
  const raw = Buffer.from(JSON.parse(f.request({ op: 'compare', args: { sealedObservation: { z: 1, a: 2 } } }).body).payload, 'base64url').toString();
  await refused(f, f.request({}, raw.replace('"a":2,"z":1', '"z":1,"a":2')));
});

test('envelope shape, duplicate fields and padded base64 are rejected', async t => {
  const f = fixture(t);
  const req = f.request();
  const envelope = JSON.parse(req.body);
  for (const body of [JSON.stringify({ ...envelope, extra: 1 }), req.body.replace('{', `{"payload":"${envelope.payload}",`), JSON.stringify({ ...envelope, payload: `${envelope.payload}=` }), JSON.stringify({ ...envelope, signature: `${envelope.signature}=` }), '{}', '{']) await refused(f, { ...req, body });
});

test('body, payload, depth and UTF8 limits reject without a handler', async t => {
  const f = fixture(t);
  await refused(f, { ...f.request(), body: 'x'.repeat(16385) });
  await refused(f, f.request({ args: { challenge: 'x'.repeat(8192) } }));
  let deep = {};
  for (let i = 0; i < 20; i += 1) deep = { next: deep };
  await refused(f, f.request({ op: 'compare', args: { sealedObservation: deep } }));
  const bytes = Buffer.from([0xff]);
  await refused(f, { ...f.request(), body: JSON.stringify({ payload: bytes.toString('base64url'), signature: sign(null, Buffer.concat([Buffer.from(requestPrefix), bytes]), windows.privateKey).toString('base64url') }) });
});

test('accepted nonces cannot replay', async t => {
  const f = fixture(t);
  const req = f.request();
  assert.deepEqual((await f.send(req)).data.result, { challenge: 'hello' });
  await failure(f, req, 'replay');
});

test('arming is local, one-shot and removes echo admission', async t => {
  const f = fixture(t);
  f.lane.arm(async () => ({ senderGrant: { sealed: 'grant' }, afterReply: async () => {} }));
  assert.equal(f.lane.state, 'armed');
  assert.throws(() => f.lane.arm(async () => {}), /Cannot arm lane/);
  await failure(f, f.request(), 'refused');
  for (const args of [{ sealedObservation: [] }, { sealedObservation: {}, binding: 'injected' }, {}]) await failure(f, f.request({ op: 'compare', args }), 'refused');
});

test('compare flushes the signed grant before afterReply and stays busy until it settles', async t => {
  const f = fixture(t);
  const finish = deferred();
  const entered = deferred();
  const events = [];
  f.lane.arm(async observation => {
    assert.deepEqual(observation, { sealed: 'observation' });
    return { senderGrant: { sealed: 'grant' }, afterReply: async () => { events.push('afterReply'); entered.resolve(); await finish.promise; } };
  });
  const request = f.request({ op: 'compare', args: { sealedObservation: { sealed: 'observation' } } });
  const operation = f.send(request, { flush: async reply => { assert.deepEqual(read(reply, request).result, { senderGrant: { sealed: 'grant' } }); events.push('flush'); } });
  await entered.promise;
  assert.deepEqual(events, ['flush', 'afterReply']);
  assert.equal(f.lane.state, 'busy');
  await failure(f, f.request(), 'busy');
  finish.resolve();
  assert.deepEqual((await operation).data.result, { senderGrant: { sealed: 'grant' } });
  assert.equal(f.lane.state, 'armed');
});

test('busy spans local handler and response flush', async t => {
  const f = fixture(t);
  const handlerGate = deferred();
  const handlerEntered = deferred();
  const flushGate = deferred();
  const flushEntered = deferred();
  f.lane.arm(async () => { handlerEntered.resolve(); await handlerGate.promise; return { senderGrant: {}, afterReply: async () => {} }; });
  const operation = f.send(f.request({ op: 'compare', args: { sealedObservation: {} } }), { flush: async () => { flushEntered.resolve(); await flushGate.promise; } });
  await handlerEntered.promise;
  await failure(f, f.request(), 'busy');
  handlerGate.resolve();
  await flushEntered.promise;
  await failure(f, f.request(), 'busy');
  flushGate.resolve();
  assert.equal((await operation).data.ok, true);
  assert.equal(f.lane.state, 'armed');
});

test('handler exception gives a safe signed failure and closes admission', async t => {
  const f = fixture(t);
  f.lane.arm(async () => { throw new Error('secret local diagnostic'); });
  const actual = await failure(f, f.request({ op: 'compare', args: { sealedObservation: {} } }), 'failed');
  assert.equal(actual.reply.body.includes('secret'), false);
  assert.equal(f.lane.state, 'stopped');
  await failure(f, f.request(), 'closed');
});

test('handler deadline aborts, signs timeout, and never runs late afterReply', async t => {
  const f = fixture(t, { handlerTimeoutMillis: 15 });
  const gate = deferred();
  let signal;
  let after = 0;
  f.lane.arm(async (_, context) => { signal = context.signal; await gate.promise; return { senderGrant: {}, afterReply: async () => { after += 1; } }; });
  await failure(f, f.request({ op: 'compare', args: { sealedObservation: {} } }), 'timeout');
  assert.equal(signal.aborted, true);
  gate.resolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(after, 0);
  assert.equal(f.lane.state, 'stopped');
});

test('flush failure closes lane and prevents afterReply', async t => {
  const f = fixture(t);
  let after = 0;
  f.lane.arm(async () => ({ senderGrant: {}, afterReply: async () => { after += 1; } }));
  const req = f.request({ op: 'compare', args: { sealedObservation: {} } });
  const actual = await f.send(req, { flush: async () => { throw new Error('secret transport error'); } });
  assert.deepEqual(actual.reply, { statusCode: 403, body: '{"error":"refused"}' });
  assert.equal(after, 0);
  assert.equal(f.lane.state, 'stopped');
});

test('disconnect before or immediately after flush prevents afterReply', async t => {
  for (const disconnectDuringFlush of [false, true]) {
    const f = fixture(t);
    let connected = disconnectDuringFlush;
    let after = 0;
    f.lane.arm(async () => ({ senderGrant: {}, afterReply: async () => { after += 1; } }));
    const req = f.request({ op: 'compare', args: { sealedObservation: {} } });
    const actual = await f.send(req, { isConnected: () => connected, flush: async () => { connected = false; } });
    assert.equal(actual.reply.statusCode, disconnectDuringFlush ? 200 : 403);
    assert.equal(after, 0);
    assert.equal(f.lane.state, 'stopped');
  }
});

test('afterReply rejection and timeout keep flushed success but stop uncertain lane', async t => {
  for (const kind of ['reject', 'timeout']) {
    const f = fixture(t, { handlerTimeoutMillis: 15 });
    let signal;
    f.lane.arm(async (_, context) => { signal = context.signal; return { senderGrant: { sealed: 'grant' }, afterReply: async () => { if (kind === 'reject') throw new Error('secret'); await new Promise(() => {}); } }; });
    const result = await f.send(f.request({ op: 'compare', args: { sealedObservation: {} } }));
    assert.deepEqual(result.data.result, { senderGrant: { sealed: 'grant' } });
    assert.equal(result.flushed.length, 1);
    assert.equal(f.lane.state, 'stopped');
    assert.equal(signal.aborted, true);
  }
});

test('invalid or oversized handler output fails signed and never releases callback', async t => {
  for (const value of [undefined, { senderGrant: {}, afterReply: async () => {}, extra: true }, { senderGrant: { sealed: 'x'.repeat(8192) }, afterReply: async () => {} }]) {
    const f = fixture(t);
    f.lane.arm(async () => value);
    await failure(f, f.request({ op: 'compare', args: { sealedObservation: {} } }), 'failed');
    assert.equal(f.lane.state, 'stopped');
  }
});

test('request budget permits exactly 32 attempts then stops', async t => {
  const f = fixture(t);
  for (let i = 0; i < 32; i += 1) assert.deepEqual((await f.send()).data.result, { challenge: 'hello' });
  assert.equal(f.lane.state, 'stopped');
  await failure(f, f.request(), 'closed');
});

test('clock expiry and explicit stop close admission and prevent rearming', async t => {
  const f = fixture(t);
  f.advance(600000);
  assert.equal(f.lane.state, 'stopped');
  await failure(f, f.request(), 'closed');
  assert.throws(() => f.lane.arm(async () => {}), /Cannot arm lane/);
  f.lane.stop();
  f.lane.stop();
  assert.equal(f.lane.state, 'stopped');
});

test('owned wall-clock expiry stops the offline lane', async t => {
  const f = fixture(t, { lifetimeMillis: 10 });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(f.lane.state, 'stopped');
});

test('configuration requires pinned Ed25519 keys and bounded limits', t => {
  const f = fixture(t);
  const rsa = generateKeyPairSync('rsa', { modulusLength: 1024 });
  for (const changes of [{ peerAddress: '0.0.0.0x' }, { channelId: 'bad' }, { lifetimeMillis: 600001 }, { handlerTimeoutMillis: 8001 }, { privateKey: mac.publicKey }, { windowsPublicKeyDer: rsa.publicKey.export({ type: 'spki', format: 'der' }).toString('base64url') }]) assert.throws(() => createJoinControlServer({ ...f.config, ...changes }));
  assert.deepEqual(Object.keys(f.lane).sort(), ['arm', 'handle', 'listen', 'state', 'stop']);
  for (const args of [{ host: '0.0.0.0', port: 9000 }, { host: '127.0.0.1', port: 9000 }, { host: '::1', port: 9000 }, { host: '10.0.0.1', port: 80 }, { host: '10.0.0.1', port: 65536 }]) assert.throws(() => f.lane.listen(args), /Explicit LAN IPv4 and port required/);
  assert.equal(f.lane.state, 'fresh');
});


test('response flush deadline closes admission without afterReply', async t => {
  const f = fixture(t, { handlerTimeoutMillis: 15 });
  let after = 0;
  f.lane.arm(async () => ({ senderGrant: {}, afterReply: async () => { after += 1; } }));
  const result = await f.send(f.request({ op: 'compare', args: { sealedObservation: {} } }), { flush: async () => new Promise(() => {}) });
  assert.deepEqual(result.reply, { statusCode: 403, body: '{"error":"refused"}' });
  assert.equal(after, 0);
  assert.equal(f.lane.state, 'stopped');
});

test('already disconnected peer never enters the compare handler', async t => {
  const f = fixture(t);
  let calls = 0;
  f.lane.arm(async () => { calls += 1; return { senderGrant: { sealed: 'grant' }, afterReply: async () => {} }; });
  const result = await f.send(f.request({ op: 'compare', args: { sealedObservation: {} } }), { isConnected: () => false });
  assert.deepEqual(result.reply, { statusCode: 403, body: '{"error":"refused"}' });
  assert.equal(calls, 0);
  assert.equal(f.lane.state, 'stopped');
  const active = fixture(t);
  active.lane.arm(async () => { calls += 1; return { senderGrant: { sealed: 'grant' }, afterReply: async () => {} }; });
  assert.deepEqual((await active.send(active.request({ op: 'compare', args: { sealedObservation: {} } }))).data.result, { senderGrant: { sealed: 'grant' } });
  assert.equal(calls, 1);
});


test('public and non-RFC1918 bind addresses are refused before creating a server', t => {
  const f = fixture(t);
  for (const host of ['8.8.8.8', '9.255.255.255', '11.0.0.1', '172.15.255.255', '172.32.0.1', '192.167.255.255', '192.169.0.1', '169.254.1.1', '224.0.0.1']) {
    assert.throws(() => f.lane.listen({ host, port: 9000 }), /Explicit LAN IPv4 and port required/);
    assert.equal(f.lane.state, 'fresh');
  }
});

test('completed response permits afterReply despite normal socket close, premature close does not', async t => {
  for (const completed of [true, false]) {
    const f = fixture(t);
    const response = { writableFinished: false };
    const socket = { destroyed: false };
    let after = 0;
    let flushed = 0;
    const events = [];
    f.lane.arm(async () => {
      events.push('handler');
      if (!completed) socket.destroyed = true;
      return { senderGrant: { sealed: 'grant' }, afterReply: async () => { after += 1; events.push('afterReply'); } };
    });
    const req = f.request({ op: 'compare', args: { sealedObservation: {} } });
    const result = await f.send(req, {
      isConnected: () => isResponseConnected(response, socket),
      flush: async reply => {
        assert.deepEqual(read(reply, req).result, { senderGrant: { sealed: 'grant' } });
        response.writableFinished = true;
        socket.destroyed = true;
        flushed += 1;
        events.push('finish');
      },
    });
    assert.equal(result.reply.statusCode, completed ? 200 : 403);
    assert.equal(flushed, completed ? 1 : 0);
    assert.equal(after, completed ? 1 : 0);
    assert.deepEqual(events, completed ? ['handler', 'finish', 'afterReply'] : ['handler']);
    assert.equal(f.lane.state, completed ? 'armed' : 'stopped');
  }
});
