import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, verify } from 'node:crypto';
import { createServer } from 'node:http';
import {
  canonical,
  createClient,
  DirectControlError,
  generateClientIdentity,
} from './join_control_client_v1.mjs';
import { createJoinControlServer, isResponseConnected } from './join_control_server_v1.mjs';

const PREFIX = Buffer.from('wired-parts/j60-test-control/request/v1\n', 'utf8');
const RESPONSE_PREFIX = Buffer.from('wired-parts/j60-test-control/response/v1\n', 'utf8');
const CHANNEL = Buffer.from('0123456789abcdef', 'utf8').toString('base64url');
const RUN = 'j60-join-v10';
const ALLOWED_ERRORS = ['refused', 'busy', 'expired', 'replay', 'failed', 'timeout', 'closed', 'not-ready'];

function b64(value) {
  const bytes = Buffer.from(value, 'base64url');
  assert.equal(bytes.toString('base64url'), value);
  return bytes;
}

function signPayload(payload, privateKey, rawOverride, prefix = RESPONSE_PREFIX) {
  const raw = rawOverride ?? Buffer.from(canonical(payload), 'utf8');
  const signature = sign(null, Buffer.concat([prefix, raw]), privateKey);
  return Buffer.from(JSON.stringify({
    payload: raw.toString('base64url'),
    signature: signature.toString('base64url'),
  }), 'utf8');
}

function signedResponse(record, serverPrivate, overrides = {}, result = { challenge: record.payload.args.challenge }) {
  const request = record.payload;
  const payload = {
    version: 1,
    run: request.run,
    channelId: request.channelId,
    nonce: request.nonce,
    requestSha256: record.requestSha256,
    ok: true,
    result,
    ...overrides,
  };
  return signPayload(payload, serverPrivate);
}

function parseRequest(body, clientPublicKey) {
  assert.ok(body.length <= 16384);
  const envelope = JSON.parse(body.toString('utf8'));
  assert.deepEqual(Object.keys(envelope).sort(), ['payload', 'signature']);
  const raw = b64(envelope.payload);
  const signature = b64(envelope.signature);
  assert.equal(signature.length, 64);
  assert.ok(raw.length <= 8192);
  assert.ok(verify(null, Buffer.concat([PREFIX, raw]), clientPublicKey, signature));
  const text = new TextDecoder('utf-8', { fatal: true }).decode(raw);
  const payload = JSON.parse(text);
  assert.equal(canonical(payload), text);
  assert.deepEqual(Object.keys(payload).sort(), [
    'args', 'channelId', 'expiresAtMillis', 'nonce', 'op', 'run', 'version',
  ]);
  assert.equal(payload.version, 1);
  assert.equal(payload.run, RUN);
  assert.equal(payload.channelId, CHANNEL);
  assert.match(payload.nonce, /^[A-Za-z0-9_-]{22}$/);
  assert.equal(b64(payload.nonce).length, 16);
  assert.ok(Number.isSafeInteger(payload.expiresAtMillis));
  assert.ok(payload.expiresAtMillis >= Date.now() && payload.expiresAtMillis <= Date.now() + 10000);
  assert.ok(payload.op === 'echo' || payload.op === 'compare');
  return {
    payload,
    requestSha256: createHash('sha256').update(raw).digest('hex'),
  };
}

let mockHandlerFailureLocation = null;
let currentMockCase = 'setup';

async function listen(handler) {
  const server = createServer((req, res) => {
    const chunks = [];
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > 16384) {
        req.destroy();
        res.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      Promise.resolve(handler(req, res, Buffer.concat(chunks, size))).catch(error => { mockHandlerFailureLocation = error.name + ': ' + error.message; res.destroy(); });
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    server,
    port: server.address().port,
    async close() {
      await new Promise(resolve => server.close(resolve));
    },
  };
}

async function harness(handler, { pinWrongServerKey = false } = {}) {
  const identity = generateClientIdentity();
  const serverPair = generateKeyPairSync('ed25519');
  const alternatePair = generateKeyPairSync('ed25519');
  const serverPublicKeySpki = (pinWrongServerKey ? alternatePair.publicKey : serverPair.publicKey)
    .export({ type: 'spki', format: 'der' }).toString('base64url');
  const clientPublicKey = (await import('node:crypto')).createPublicKey({
    key: b64(identity.publicKeySpki), format: 'der', type: 'spki',
  });
  const records = [];
  const httpServer = await listen(async (req, res, body) => {
    assert.equal(req.method, 'POST');
    assert.equal(req.url, '/join-control');
    const parsed = parseRequest(body, clientPublicKey);
    records.push(parsed);
    await handler({ req, res, body, parsed, serverPair, alternatePair, records });
  });
  const client = createClient({
    host: '127.0.0.1',
    port: httpServer.port,
    run: RUN,
    channelId: CHANNEL,
    serverPublicKeySpki,
    identity,
  });
  return { client, identity, serverPair, alternatePair, records, ...httpServer };
}

function send(res, body, status = 200, headers = {}) {
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(body);
}

function basicPayload(record, result = { challenge: record.payload.args.challenge }, overrides = {}) {
  const request = record.payload;
  return {
    version: 1,
    run: request.run,
    channelId: request.channelId,
    nonce: request.nonce,
    requestSha256: record.requestSha256,
    ok: true,
    result,
    ...overrides,
  };
}

async function assertUnknownAndBlocked(client, records, expectedCode) {
  const pending = client.pending;
  assert.ok(pending);
  assert.equal(pending.state, 'unknown');
  assert.match(pending.requestSha256, /^[a-f0-9]{64}$/);
  assert.ok(Buffer.isBuffer(pending.rawPayload));
  assert.ok(Buffer.isBuffer(pending.requestBody));
  await assert.rejects(client.request('echo', { challenge: 'second' }), error =>
    error instanceof DirectControlError && error.code === 'pending_unknown' && error.outcome === 'unknown');
  await assert.rejects(Promise.resolve().then(() => client.resolveUnknown()), error =>
    error instanceof DirectControlError && error.code === 'operator_confirmation_required');
  assert.equal(records.length, 1);
  if (expectedCode) return;
  client.resolveUnknown({ outcomeKnown: true });
  assert.equal(client.pending, null);
}

function clientOptions(h) {
  return {
    host: '127.0.0.1',
    port: h.port,
    run: RUN,
    channelId: CHANNEL,
    serverPublicKeySpki: h.serverPair.publicKey.export({ type: 'spki', format: 'der' }).toString('base64url'),
    identity: h.identity,
  };
}

try {
  currentMockCase = 'canonicalization';
  assert.equal(canonical({ z: 2, a: { y: true, x: [1, 'v'] } }), '{"a":{"x":[1,"v"],"y":true},"z":2}');
  const protoSafe = Object.create(null);
  Object.defineProperty(protoSafe, '__proto__', { value: 'data', enumerable: true });
  protoSafe.a = 1;
  assert.equal(canonical(protoSafe), '{"__proto__":"data","a":1}');
  for (const bad of [NaN, Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1, -0, undefined, 1n, new Date()]) {
    assert.throws(() => canonical({ bad }));
  }
  const tooDeep = {};
  let cursor = tooDeep;
  for (let i = 0; i < 17; i++) {
    cursor.next = {};
    cursor = cursor.next;
  }
  assert.throws(() => canonical(tooDeep), /nesting limit/);
  const sparse = [];
  sparse[1] = 'x';
  assert.throws(() => canonical(sparse));

  const identityOnly = generateClientIdentity();
  const serverOnly = generateKeyPairSync('ed25519');
  const serverSpkiOnly = serverOnly.publicKey.export({ type: 'spki', format: 'der' }).toString('base64url');
  for (const run of [undefined, null, '', 'j61-created-v1', 'j61-created-v3', 'company-j61-created-v2', 'j60-join-v10 ', ['j61-created-v2']]) {
    assert.throws(() => createClient({
      host: '127.0.0.1', port: 1234, run, channelId: CHANNEL,
      serverPublicKeySpki: serverSpkiOnly, identity: identityOnly,
    }), /run must be/);
  }
  for (const badHost of ['example.com', '8.8.8.8', '0.0.0.0', '127.0.0.2', '169.254.1.1']) {
    assert.throws(() => createClient({
      host: badHost, port: 1234, run: RUN, channelId: CHANNEL,
      serverPublicKeySpki: serverSpkiOnly, identity: identityOnly,
    }), /host must be/);
  }
  assert.throws(() => createClient({
    host: '127.0.0.1', port: 1234, run: RUN, channelId: 'short',
    serverPublicKeySpki: serverSpkiOnly, identity: identityOnly,
  }), /channelId/);
  assert.throws(() => createClient({
    host: '127.0.0.1', port: 1234, run: RUN, channelId: CHANNEL,
    serverPublicKeySpki: serverOnly.publicKey.export({ type: 'spki', format: 'der' }).toString('base64'),
    identity: identityOnly,
  }), /valid Ed25519 SPKI/);
  const wrongIdentity = generateClientIdentity();
  assert.throws(() => createClient({
    host: '127.0.0.1', port: 1234, run: RUN, channelId: CHANNEL,
    serverPublicKeySpki: serverSpkiOnly,
    identity: { privateKeyObject: identityOnly.privateKeyObject, publicKeySpki: wrongIdentity.publicKeySpki },
  }), /does not match/);

  let localRequestCount = 0;
  currentMockCase = 'successful echo and compare';
  const success = await harness(async ({ res, parsed, serverPair }) => {
    localRequestCount++;
    const request = parsed.payload;
    if (request.op === 'echo') {
      assert.deepEqual(request.args, { challenge: 'synthetic-echo' });
      send(res, signedResponse(parsed, serverPair.privateKey, {}, { challenge: request.args.challenge }));
    } else {
      assert.deepEqual(request.args, { sealedObservation: { marker: 'synthetic-only', n: 7 } });
      send(res, signedResponse(parsed, serverPair.privateKey, {}, {
        senderGrant: { accepted: true, evidence: { count: 1 } },
      }));
    }
  });
  try {
    currentMockCase = 'success echo';
    const echo = await success.client.request('echo', { challenge: 'synthetic-echo' });
    assert.deepEqual(echo.result, { challenge: 'synthetic-echo' });
    assert.ok(Number.isSafeInteger(echo.elapsedMs) && echo.elapsedMs >= 0);
    assert.equal(success.client.pending, null);
    currentMockCase = 'success compare';
    const compare = await success.client.request('compare', {
      sealedObservation: { marker: 'synthetic-only', n: 7 },
    });
    assert.deepEqual(compare.result, { senderGrant: { accepted: true, evidence: { count: 1 } } });
    assert.ok(Number.isSafeInteger(compare.elapsedMs) && compare.elapsedMs >= 0);
    assert.equal(success.client.pending, null);
    assert.equal(success.records.length, 2);
    assert.notEqual(success.records[0].payload.nonce, success.records[1].payload.nonce);
  } finally {
    await success.close();
  }
  assert.equal(localRequestCount, 2);

  currentMockCase = 'bad pinned key';
  const badPinnedKey = await harness(async ({ res, parsed, serverPair }) => {
    send(res, signedResponse(parsed, serverPair.privateKey));
  }, { pinWrongServerKey: true });
  try {
    await assert.rejects(badPinnedKey.client.request('echo', { challenge: 'bad-key' }), error =>
      error instanceof DirectControlError && error.code === 'invalid_signature' && error.outcome === 'unknown');
    await assertUnknownAndBlocked(badPinnedKey.client, badPinnedKey.records, 'invalid_signature');
  } finally {
    await badPinnedKey.close();
  }

  const responseCases = [
    ['wrong-signature-domain', ({ res, parsed, serverPair }) => {
      send(res, signPayload(basicPayload(parsed), serverPair.privateKey, undefined, PREFIX));
    }, 'invalid_signature'],
    ['bad-signature', ({ res, parsed, serverPair }) => {
      const body = signedResponse(parsed, serverPair.privateKey);
      const envelope = JSON.parse(body.toString('utf8'));
      const bytes = b64(envelope.signature);
      bytes[0] ^= 1;
      envelope.signature = bytes.toString('base64url');
      send(res, Buffer.from(JSON.stringify(envelope)));
    }, 'invalid_signature'],
    ['wrong-nonce', ({ res, parsed, serverPair }) => {
      send(res, signPayload(basicPayload(parsed, undefined, { nonce: 'AAAAAAAAAAAAAAAAAAAAAA' }), serverPair.privateKey));
    }, 'invalid_response'],
    ['wrong-hash', ({ res, parsed, serverPair }) => {
      send(res, signPayload(basicPayload(parsed, undefined, { requestSha256: '0'.repeat(64) }), serverPair.privateKey));
    }, 'invalid_response'],
    ['wrong-channel', ({ res, parsed, serverPair }) => {
      send(res, signPayload(basicPayload(parsed, undefined, { channelId: Buffer.alloc(16, 3).toString('base64url') }), serverPair.privateKey));
    }, 'invalid_response'],
    ['wrong-run', ({ res, parsed, serverPair }) => {
      send(res, signPayload(basicPayload(parsed, undefined, { run: 'j60-join-v8' }), serverPair.privateKey));
    }, 'invalid_response'],
    ['bad-base64url', ({ res }) => send(res, Buffer.from('{"payload":"AA=","signature":"AA"}')), 'invalid_response'],
    ['malformed-envelope', ({ res }) => send(res, Buffer.from('not-json')), 'invalid_response'],
    ['oversized-response', ({ res }) => send(res, Buffer.alloc(16385, 65)), 'transport_error'],
    ['oversized-raw-payload', ({ res, parsed, serverPair }) => {
      const response = basicPayload(parsed, { challenge: 'x'.repeat(9000) });
      send(res, signPayload(response, serverPair.privateKey));
    }, 'invalid_response'],
    ['noncanonical-payload', ({ res, parsed, serverPair }) => {
      const response = basicPayload(parsed);
      const raw = Buffer.from(' ' + canonical(response) + ' ', 'utf8');
      send(res, signPayload(response, serverPair.privateKey, raw));
    }, 'invalid_response'],
  ];
  for (const [name, handler, expectedCode] of responseCases) {
    currentMockCase = name;
    const h = await harness(async context => handler(context));
    try {
      await assert.rejects(h.client.request('echo', { challenge: name }), error => { if (!(error instanceof DirectControlError && error.code === expectedCode && error.outcome === 'unknown')) console.error('case mismatch '+name+' got '+(error?.code??'?')+' '+(error?.outcome??'?')+' expected '+expectedCode); return error instanceof DirectControlError && error.code === expectedCode && error.outcome === 'unknown'; });
      await assertUnknownAndBlocked(h.client, h.records, expectedCode);
    } finally {
      await h.close();
    }
  }

  const statusCases = [403, 302, 503];
  for (const status of statusCases) {
    currentMockCase = 'http status ' + status;
    let requestCount = 0;
    const h = await harness(async ({ res }) => {
      requestCount++;
      send(res, Buffer.from('fixed synthetic status response'), status,
        status === 302 ? { location: 'http://127.0.0.1:1/redirect-target' } : {});
    });
    try {
      await assert.rejects(h.client.request('echo', { challenge: 'status' }), error =>
        error instanceof DirectControlError && error.code === 'http_status' &&
        error.statusCode === status && error.outcome === 'unknown');
      await assertUnknownAndBlocked(h.client, h.records, 'http_status');
      assert.equal(requestCount, 1);
    } finally {
      await h.close();
    }
  }

  currentMockCase = 'signed failure';
  const signedFailure = await harness(async ({ res, parsed, serverPair }) => {
    const failed = basicPayload(parsed, { error: 'timeout' }, { ok: false });
    send(res, signPayload(failed, serverPair.privateKey));
  });
  try {
    await assert.rejects(signedFailure.client.request('echo', { challenge: 'signed-failure' }), error =>
      error instanceof DirectControlError && error.code === 'timeout' && error.authenticated &&
      error.outcome === 'unknown');
    await assertUnknownAndBlocked(signedFailure.client, signedFailure.records, 'timeout');
  } finally {
    await signedFailure.close();
  }

  currentMockCase = 'bad failure code';
  const badFailureCode = await harness(async ({ res, parsed, serverPair }) => {
    send(res, signPayload(basicPayload(parsed, { error: 'arbitrary' }, { ok: false }), serverPair.privateKey));
  });
  try {
    await assert.rejects(badFailureCode.client.request('echo', { challenge: 'bad-code' }), error =>
      error instanceof DirectControlError && error.code === 'invalid_response' && error.outcome === 'unknown');
    await assertUnknownAndBlocked(badFailureCode.client, badFailureCode.records, 'invalid_response');
  } finally {
    await badFailureCode.close();
  }

  currentMockCase = 'replayed response';
  let cachedResponse;
  const replay = await harness(async ({ res, parsed, serverPair }) => {
    if (cachedResponse === undefined) {
      cachedResponse = signedResponse(parsed, serverPair.privateKey);
    }
    send(res, cachedResponse);
  });
  try {
    const first = await replay.client.request('echo', { challenge: 'first' });
    assert.equal(first.result.challenge, 'first');
    await assert.rejects(replay.client.request('echo', { challenge: 'second' }), error =>
      error instanceof DirectControlError && error.code === 'invalid_response' && error.outcome === 'unknown');
    assert.equal(replay.client.pending.state, 'unknown');
    await assert.rejects(replay.client.request('echo', { challenge: 'third' }), error =>
      error instanceof DirectControlError && error.code === 'pending_unknown' && error.outcome === 'unknown');
    replay.client.resolveUnknown({ outcomeKnown: true });
    assert.equal(replay.client.pending, null);
    assert.equal(replay.records.length, 2);
    assert.notEqual(replay.records[0].payload.nonce, replay.records[1].payload.nonce);
  } finally {
    await replay.close();
  }

  currentMockCase = 'local validation';
  const localValidation = await harness(async () => {
    throw new Error('invalid local arguments must not reach server');
  });
  try {
    await assert.rejects(localValidation.client.request('echo', { challenge: '' }), /challenge length/);
    await assert.rejects(localValidation.client.request('echo', { challenge: 'x', extra: true }), /only challenge/);
    await assert.rejects(localValidation.client.request('compare', { sealedObservation: [], extra: true }), /plain sealedObservation/);
    await assert.rejects(localValidation.client.request('compare', { sealedObservation: new Date() }), /plain sealedObservation/);
    await assert.rejects(localValidation.client.request('unknown', {}), /unsupported control operation/);
    await assert.rejects(localValidation.client.request('compare', {
      sealedObservation: { payload: 'x'.repeat(9000) },
    }), /raw limit/);
    assert.equal(localValidation.records.length, 0);
    assert.equal(localValidation.client.pending, null);
  } finally {
    await localValidation.close();
  }

  currentMockCase = 'timeout';
  const timeoutHarness = await harness(async () => {
    // Deliberately leave this loopback response open to exercise the fixed request timeout.
  });
  try {
    await assert.rejects(timeoutHarness.client.request('echo', { challenge: 'timeout' }), error =>
      error instanceof DirectControlError && error.code === 'timeout' && error.outcome === 'unknown');
    await assertUnknownAndBlocked(timeoutHarness.client, timeoutHarness.records, 'timeout');
  } finally {
    await timeoutHarness.close();
  }


  for (const interopRun of [RUN, 'j61-created-v2']) {
  currentMockCase = 'actual server loopback interoperability ' + interopRun;
  const interopIdentity = generateClientIdentity();
  const interopPair = generateKeyPairSync('ed25519');
  const interopPin = interopPair.publicKey.export({ type: 'spki', format: 'der' }).toString('base64url');
  let interopCalls = 0;
  let interopAfterReply = 0;
  let interopFinished = 0;
  let interopAfterFlush = false;
  const actualServer = createJoinControlServer({
    ...(interopRun === RUN ? {} : { run: interopRun }),
    channelId: CHANNEL,
    windowsPublicKeyDer: interopIdentity.publicKeySpki,
    privateKey: interopPair.privateKey,
    peerAddress: '127.0.0.1',
    now: () => Date.now() - 500,
    lifetimeMillis: 60000,
  });
  const actualHttp = createServer((req, res) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      void actualServer.handle({
        method: req.method,
        path: req.url,
        body: Buffer.concat(chunks),
        peerAddress: '127.0.0.1',
      }, {
        isConnected: () => isResponseConnected(res, req.socket),
        flush: reply => new Promise((resolve, reject) => {
          res.once('finish', () => {
            interopFinished++;
            resolve();
          });
          res.once('error', reject);
          res.writeHead(reply.statusCode, {
            'content-type': 'application/json',
            'content-length': Buffer.byteLength(reply.body),
            connection: 'close',
          });
          res.end(reply.body);
        }),
      });
    });
  });
  await new Promise((resolve, reject) => {
    actualHttp.once('error', reject);
    actualHttp.listen(0, '127.0.0.1', resolve);
  });
  try {
    const actualClient = createClient({
      host: '127.0.0.1',
      port: actualHttp.address().port,
      run: interopRun,
      channelId: CHANNEL,
      serverPublicKeySpki: interopPin,
      identity: interopIdentity,
    });
    const echo = await actualClient.request('echo', { challenge: 'actual-server-echo' });
    assert.deepEqual(echo.result, { challenge: 'actual-server-echo' });
    actualServer.arm(async () => {
      interopCalls++;
      return {
        senderGrant: { synthetic: true },
        afterReply: async () => {
          interopAfterReply++;
          interopAfterFlush = interopFinished >= 2;
        },
      };
    });
    const compare = await actualClient.request('compare', { sealedObservation: { synthetic: true } });
    assert.deepEqual(compare.result, { senderGrant: { synthetic: true } });
    assert.equal(interopCalls, 1);
    assert.equal(interopAfterReply, 1);
    assert.equal(interopAfterFlush, true);
    const otherRunClient = createClient({
      host: '127.0.0.1',
      port: actualHttp.address().port,
      run: interopRun === RUN ? 'j61-created-v2' : RUN,
      channelId: CHANNEL,
      serverPublicKeySpki: interopPin,
      identity: interopIdentity,
    });
    await assert.rejects(otherRunClient.request('compare', { sealedObservation: { synthetic: true } }), error =>
      error instanceof DirectControlError && error.code === 'invalid_response' && error.outcome === 'unknown');
    assert.equal(otherRunClient.pending.state, 'unknown');
    await assert.rejects(otherRunClient.request('echo', { challenge: 'cross-run-blocked' }), error =>
      error instanceof DirectControlError && error.code === 'pending_unknown' && error.outcome === 'unknown');
    assert.equal(interopCalls, 1);
    const wrongKeyClient = createClient({
      host: '127.0.0.1',
      port: actualHttp.address().port,
      run: interopRun,
      channelId: CHANNEL,
      serverPublicKeySpki: interopPin,
      identity: generateClientIdentity(),
    });
    await assert.rejects(wrongKeyClient.request('echo', { challenge: 'wrong-key' }), error =>
      error instanceof DirectControlError && error.code === 'http_status' && error.outcome === 'unknown');
    assert.equal(interopCalls, 1);
  } finally {
    actualServer.stop();
    await new Promise(resolve => actualHttp.close(resolve));
  }
  }

  console.log('PASS canonicalization, private identity lifecycle, strict signed loopback echo/compare, failure and framing rejection, replay binding, timeout unknown retention, and explicit resolution');
} catch (error) {
  if (error instanceof DirectControlError) {
    console.error('FAIL direct-control contract code=' + error.code + ' outcome=' + error.outcome + ' at ' + (error.stack?.split(/\r?\n/).find(line => line.includes('join_direct_control_client_v1.test.mjs')) ?? 'unknown test location') + ' case=' + currentMockCase + ' mock=' + (mockHandlerFailureLocation ?? 'none'));
  } else {
    console.error('FAIL direct-control mock assertion ' + error.name + ' ' + error.message + ' case=' + currentMockCase + ' mock=' + (mockHandlerFailureLocation ?? 'none') + ' at ' + (error.stack?.split(/\r?\n/).find(line => line.includes('join_direct_control_client_v1.test.mjs')) ?? 'unknown test location'));
  }
  process.exitCode = 1;
}
