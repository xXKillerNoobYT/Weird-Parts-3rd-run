import { createHash, createPublicKey, sign, verify } from 'node:crypto';
import { createServer } from 'node:http';
import { isIPv4 } from 'node:net';

const RUN = 'j60-join-v10';
const ALLOWED_RUNS = new Set([RUN, 'j61-created-v19']);
const REQUEST_PREFIX = 'wired-parts/j60-test-control/request/v1\n';
const RESPONSE_PREFIX = 'wired-parts/j60-test-control/response/v1\n';
const MAX_BODY = 16384;
const MAX_PAYLOAD = 8192;
const REFUSED = Object.freeze({ statusCode: 403, body: '{"error":"refused"}' });
const ERRORS = new Set(['refused', 'busy', 'expired', 'replay', 'failed', 'timeout', 'closed', 'not-ready']);

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function shape(value, keys) {
  return object(value) && Object.keys(value).sort().join('\0') === [...keys].sort().join('\0');
}

function canonical(value, depth = 0) {
  if (depth > 16) throw new Error('refused');
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number' && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(item => canonical(item, depth + 1)).join(',')}]`;
  if (object(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key], depth + 1)}`).join(',')}}`;
  throw new Error('refused');
}

function decode(value, maximum, exact) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value) || value.length > Math.ceil(maximum * 4 / 3)) throw new Error('refused');
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length > maximum || (exact !== undefined && bytes.length !== exact) || bytes.toString('base64url') !== value) throw new Error('refused');
  return bytes;
}

function utf8(bytes) {
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

function peer(value) {
  return typeof value === 'string' && value.startsWith('::ffff:') ? value.slice(7) : value;
}

function isLanIPv4(host) {
  if (!isIPv4(host)) return false;
  const [first, second] = host.split('.').map(Number);
  return first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168);
}

export function isResponseConnected(response, socket) {
  return response.writableFinished || !socket.destroyed;
}

function bounded(promise, milliseconds, onTimeout) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      onTimeout();
      reject(new Error('timeout'));
    }, milliseconds);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

export function createJoinControlServer({ channelId, windowsPublicKeyDer, privateKey, peerAddress, run = RUN, now = Date.now, lifetimeMillis = 600000, handlerTimeoutMillis = 8000 }) {
  decode(channelId, 16, 16);
  if (!ALLOWED_RUNS.has(run) || !isIPv4(peerAddress) || !Number.isInteger(lifetimeMillis) || lifetimeMillis < 1 || lifetimeMillis > 600000 || !Number.isInteger(handlerTimeoutMillis) || handlerTimeoutMillis < 1 || handlerTimeoutMillis > 8000 || typeof now !== 'function') throw new Error('Invalid local configuration');
  const publicKey = createPublicKey({ key: decode(windowsPublicKeyDer, 128), format: 'der', type: 'spki' });
  if (publicKey.asymmetricKeyType !== 'ed25519' || privateKey?.type !== 'private' || privateKey.asymmetricKeyType !== 'ed25519') throw new Error('Ed25519 keys required');
  const expires = now() + lifetimeMillis;
  const nonces = new Set();
  let lane = { kind: 'fresh' };
  let handler;
  let count = 0;
  let server;
  let activeController;
  let armedOnce = false;
  const expirationTimer = setTimeout(stop, lifetimeMillis);
  expirationTimer.unref();

  function stop() {
    lane = { kind: 'stopped' };
    clearTimeout(expirationTimer);
    activeController?.abort();
    if (server) {
      server.close();
      server.closeAllConnections();
    }
  }

  function live() {
    if (now() >= expires) stop();
    return lane.kind !== 'stopped';
  }

  function arm(localHandler) {
    if (!live() || lane.kind !== 'fresh' || armedOnce || typeof localHandler !== 'function') throw new Error('Cannot arm lane');
    handler = localHandler;
    armedOnce = true;
    lane = { kind: 'armed' };
  }

  function signed(payload, requestBytes, ok, result) {
    if (!ok && !ERRORS.has(result.error)) throw new Error('Invalid local error');
    const raw = canonical({ version: 1, run, channelId, nonce: payload.nonce, requestSha256: createHash('sha256').update(requestBytes).digest('hex'), ok, result });
    if (Buffer.byteLength(raw) > MAX_PAYLOAD) throw new Error('Invalid local result');
    const body = JSON.stringify({ payload: Buffer.from(raw).toString('base64url'), signature: sign(null, Buffer.from(RESPONSE_PREFIX + raw), privateKey).toString('base64url') });
    if (Buffer.byteLength(body) > MAX_BODY) throw new Error('Invalid local result');
    return { statusCode: 200, body };
  }

  function authenticate(request) {
    if (peer(request.peerAddress) !== peerAddress || request.method !== 'POST' || request.path !== '/join-control') return null;
    if (!(typeof request.body === 'string' || Buffer.isBuffer(request.body)) || Buffer.byteLength(request.body) > MAX_BODY) return null;
    try {
      const envelopeText = utf8(Buffer.from(request.body));
      const field = '"(?:payload|signature)"\\s*:\\s*"[A-Za-z0-9_-]+"';
      if (!new RegExp(`^\\s*\\{\\s*${field}\\s*,\\s*${field}\\s*\\}\\s*$`).test(envelopeText)) return null;
      const envelope = JSON.parse(envelopeText);
      if (!shape(envelope, ['payload', 'signature'])) return null;
      const bytes = decode(envelope.payload, MAX_PAYLOAD);
      const raw = utf8(bytes);
      const payload = JSON.parse(raw);
      if (canonical(payload) !== raw || !object(payload) || !verify(null, Buffer.from(REQUEST_PREFIX + raw), publicKey, decode(envelope.signature, 64, 64))) return null;
      decode(payload.nonce, 16, 16);
      return { payload, bytes };
    } catch {
      return null;
    }
  }

  async function handle(request, { flush, isConnected = () => true } = {}) {
    if (typeof flush !== 'function' || typeof isConnected !== 'function') throw new Error('Response transport required');
    const authenticated = authenticate(request);
    const isLive = live();
    count += 1;
    if (count > 32) stop();
    if (!authenticated) {
      try { await bounded(Promise.resolve().then(() => flush(REFUSED)), Math.min(handlerTimeoutMillis, Math.max(1, expires - now())), stop); } catch { stop(); }
      return REFUSED;
    }
    const { payload, bytes } = authenticated;
    const respond = async (ok, result) => {
      const response = signed(payload, bytes, ok, result);
      if (!isConnected()) throw new Error('closed');
      await bounded(Promise.resolve().then(() => flush(response)), Math.min(handlerTimeoutMillis, Math.max(1, expires - now())), stop);
      return response;
    };
    let error;
    if (!isLive || lane.kind === 'stopped') error = 'closed';
    else if (lane.kind === 'busy') error = 'busy';
    else if (!shape(payload, ['version', 'run', 'channelId', 'op', 'nonce', 'expiresAtMillis', 'args']) || payload.version !== 1 || payload.run !== run || payload.channelId !== channelId) error = 'refused';
    else if (!Number.isSafeInteger(payload.expiresAtMillis) || payload.expiresAtMillis <= now() || payload.expiresAtMillis - now() > 10000) error = 'expired';
    else if (nonces.has(payload.nonce)) error = 'replay';
    else if (payload.op === 'echo') {
      if (lane.kind !== 'fresh' || !shape(payload.args, ['challenge']) || typeof payload.args.challenge !== 'string' || payload.args.challenge.length > 64) error = 'refused';
    } else if (payload.op === 'compare') {
      if (lane.kind !== 'armed') error = 'not-ready';
      else if (!shape(payload.args, ['sealedObservation']) || !object(payload.args.sealedObservation)) error = 'refused';
    } else error = 'refused';
    if (error) {
      try { return await respond(false, { error }); } catch { stop(); return REFUSED; }
    }
    if (!isConnected()) { stop(); return REFUSED; }
    nonces.add(payload.nonce);
    const previous = lane.kind;
    lane = { kind: 'busy', previous };
    const controller = new AbortController();
    activeController = controller;
    let response;
    try {
      if (payload.op === 'echo') {
        response = await respond(true, { challenge: payload.args.challenge });
      } else {
        let comparison;
        try {
          comparison = await bounded(Promise.resolve().then(() => handler(payload.args.sealedObservation, { signal: controller.signal })), Math.min(handlerTimeoutMillis, Math.max(1, expires - now())), () => controller.abort());
          if (!shape(comparison, ['senderGrant', 'afterReply']) || !object(comparison.senderGrant) || typeof comparison.afterReply !== 'function') throw new Error('failed');
          signed(payload, bytes, true, { senderGrant: comparison.senderGrant });
        } catch (cause) {
          const failure = cause?.message === 'timeout' ? 'timeout' : 'failed';
          lane = { kind: 'stopped' };
          controller.abort();
          try { return await respond(false, { error: failure }); } catch { return REFUSED; } finally { stop(); }
        }
        if (!live() || controller.signal.aborted || !isConnected()) {
          stop();
          return REFUSED;
        }
        response = await respond(true, { senderGrant: comparison.senderGrant });
        if (!live() || !isConnected()) {
          stop();
          return response;
        }
        await bounded(Promise.resolve().then(() => comparison.afterReply()), Math.min(handlerTimeoutMillis, Math.max(1, expires - now())), () => stop());
      }
      if (live()) lane = { kind: previous };
      if (count >= 32) stop();
      return response;
    } catch {
      stop();
      return response ?? REFUSED;
    } finally {
      activeController = undefined;
    }
  }

  function listen({ host, port }) {
    if (!live() || server || !isLanIPv4(host) || !Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Explicit LAN IPv4 and port required');
    server = createServer({ maxHeaderSize: 4096, connectionsCheckingInterval: 1000 }, (request, response) => {
      const chunks = [];
      let size = 0;
      request.on('data', chunk => {
        size += chunk.length;
        if (size > MAX_BODY) { request.destroy(); return; }
        chunks.push(chunk);
      });
      request.on('end', () => {
        void handle({ method: request.method, path: request.url, body: Buffer.concat(chunks), peerAddress: request.socket.remoteAddress }, {
          isConnected: () => isResponseConnected(response, request.socket),
          flush: reply => new Promise((resolve, reject) => {
            const closed = () => { cleanup(); reject(new Error('closed')); };
            const finished = () => { cleanup(); resolve(); };
            const cleanup = () => { response.off('close', closed); response.off('error', closed); response.off('finish', finished); };
            response.once('close', closed);
            response.once('error', closed);
            response.once('finish', finished);
            response.writeHead(reply.statusCode, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(reply.body), 'cache-control': 'no-store', connection: 'close' });
            response.end(reply.body);
          }),
        }).catch(() => { stop(); response.destroy(); });
      });
      request.on('error', () => {});
    });
    server.headersTimeout = 5000;
    server.requestTimeout = 10000;
    server.keepAliveTimeout = 1000;
    server.maxHeadersCount = 16;
    server.maxRequestsPerSocket = 1;
    server.maxConnections = 2;
    server.on('connection', socket => {
      const timer = setTimeout(() => socket.destroy(), 10000);
      socket.once('close', () => clearTimeout(timer));
      socket.setTimeout(10000, () => socket.destroy());
    });
    server.on('error', stop);
    server.listen({ host, port, exclusive: true });
    return server;
  }

  return Object.freeze({ handle, arm, stop, listen, get state() { live(); return lane.kind; } });
}
