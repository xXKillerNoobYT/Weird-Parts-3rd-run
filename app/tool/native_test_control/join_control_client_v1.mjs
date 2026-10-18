import { createHash, createPublicKey, generateKeyPairSync, randomBytes, sign, verify } from 'node:crypto';
import { isIPv4 } from 'node:net';
import http from 'node:http';
import { TextDecoder } from 'node:util';

const REQUEST_PREFIX = Buffer.from('wired-parts/j60-test-control/request/v1\n', 'utf8');
const RESPONSE_PREFIX = Buffer.from('wired-parts/j60-test-control/response/v1\n', 'utf8');
const MAX_RAW = 8192;
const MAX_BODY = 16384;
const REQUEST_TIMEOUT_MS = 12000;
const ALLOWED_RUNS = new Set(['j60-join-v10', 'j61-created-v14']);
const FAILURE_CODES = new Set(['refused', 'busy', 'expired', 'replay', 'failed', 'timeout', 'closed', 'not-ready']);

export class DirectControlError extends Error {
  constructor(code, message, { outcome = 'known', requestSha256, statusCode, authenticated = false } = {}) {
    super(message);
    this.name = 'DirectControlError';
    this.code = code;
    this.outcome = outcome;
    if (requestSha256) this.requestSha256 = requestSha256;
    if (statusCode !== undefined) this.statusCode = statusCode;
    this.authenticated = authenticated;
  }
}

function plainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, expected) {
  if (!plainObject(value)) return false;
  const actual = Reflect.ownKeys(value);
  return actual.length === expected.length && actual.every(key => typeof key === 'string' && expected.includes(key));
}

function serializeCanonical(value, ancestors, depth = 0) {
  if (depth > 16) throw new TypeError('canonical value exceeds nesting limit');
  if (value === null) return 'null';
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value) || Object.is(value, -0)) throw new TypeError('canonical numbers must be safe integers');
    return String(value);
  }
  if (typeof value !== 'object') throw new TypeError('canonical value has unsupported type');
  if (ancestors.has(value)) throw new TypeError('canonical value contains a cycle');
  ancestors.add(value);
  try {
    if (Array.isArray(value)) {
      if (Object.getPrototypeOf(value) !== Array.prototype || Reflect.ownKeys(value).length !== value.length + 1) {
        throw new TypeError('canonical array must be dense and plain');
      }
      const entries = [];
      for (let index = 0; index < value.length; index++) {
        const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
        if (!descriptor || !descriptor.enumerable || !Object.hasOwn(descriptor, 'value')) {
          throw new TypeError('canonical array must be dense and data-only');
        }
        entries.push(serializeCanonical(descriptor.value, ancestors, depth + 1));
      }
      return '[' + entries.join(',') + ']';
    }
    if (!plainObject(value)) throw new TypeError('canonical objects must be plain');
    const descriptors = Object.getOwnPropertyDescriptors(value);
    const keys = Reflect.ownKeys(value);
    if (keys.some(key => typeof key !== 'string')) throw new TypeError('canonical object cannot have symbol keys');
    const sorted = keys.sort();
    const entries = [];
    for (const key of sorted) {
      const descriptor = descriptors[key];
      if (!descriptor.enumerable || !Object.hasOwn(descriptor, 'value')) {
        throw new TypeError('canonical object must contain enumerable data properties only');
      }
      entries.push(JSON.stringify(key) + ':' + serializeCanonical(descriptor.value, ancestors, depth + 1));
    }
    return '{' + entries.join(',') + '}';
  } finally {
    ancestors.delete(value);
  }
}

export function canonical(value) {
  return serializeCanonical(value, new Set(), 0);
}

function decodeBase64Url(value, label) {
  if (typeof value !== 'string' || value.length === 0 || !/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) {
    throw new TypeError(label + ' is not strict base64url');
  }
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.toString('base64url') !== value) throw new TypeError(label + ' is not canonical base64url');
  return bytes;
}

function loadEd25519Public(value, label) {
  let der;
  try {
    der = decodeBase64Url(value, label);
    const key = createPublicKey({ key: der, format: 'der', type: 'spki' });
    if (key.asymmetricKeyType !== 'ed25519') throw new TypeError(label + ' is not Ed25519');
    return { key, der };
  } catch {
    throw new TypeError(label + ' is not a valid Ed25519 SPKI key');
  }
}

function normalizeIdentity(identity) {
  if (!plainObject(identity) || !identity.privateKeyObject || typeof identity.publicKeySpki !== 'string') {
    throw new TypeError('identity must contain privateKeyObject and publicKeySpki');
  }
  const privateKey = identity.privateKeyObject;
  if (privateKey.type !== 'private' || privateKey.asymmetricKeyType !== 'ed25519') {
    throw new TypeError('identity private key must be Ed25519');
  }
  const { der: publicBytes } = loadEd25519Public(identity.publicKeySpki, 'identity public key');
  const derived = createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
  if (!derived.equals(publicBytes)) throw new TypeError('identity public key does not match private key');
  return { privateKey, publicKeySpki: identity.publicKeySpki };
}

export function generateClientIdentity() {
  const pair = generateKeyPairSync('ed25519');
  const publicKeySpki = pair.publicKey.export({ type: 'spki', format: 'der' }).toString('base64url');
  return Object.freeze({ privateKeyObject: pair.privateKey, publicKeySpki });
}

function requestArguments(op, args) {
  if (!plainObject(args)) throw new TypeError('request arguments must be a plain object');
  if (op === 'echo') {
    if (!exactKeys(args, ['challenge']) || typeof args.challenge !== 'string') {
      throw new TypeError('echo arguments must contain only challenge');
    }
    const length = Array.from(args.challenge).length;
    if (length < 1 || length > 64) throw new TypeError('echo challenge length must be 1..64');
    return { challenge: args.challenge };
  }
  if (op === 'compare') {
    if (!exactKeys(args, ['sealedObservation']) || !plainObject(args.sealedObservation)) {
      throw new TypeError('compare arguments must contain only a plain sealedObservation');
    }
    return { sealedObservation: args.sealedObservation };
  }
  throw new TypeError('unsupported control operation');
}

function error(code, message, options) {
  return new DirectControlError(code, message, options);
}

function postBody({ host, port, body, requestSha256 }) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer;
    const finish = (failure, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (failure) reject(failure);
      else resolve(value);
    };
    let req;
    try {
      req = http.request({
        hostname: host,
        family: 4,
        port,
        method: 'POST',
        path: '/join-control',
        agent: false,
        headers: {
          'content-type': 'application/json',
          'content-length': String(body.length),
          connection: 'close',
        },
      }, res => {
        if (res.statusCode !== 200) {
          const failure = error('http_status', 'control server returned a non-200 status', {
            outcome: 'unknown', requestSha256, statusCode: res.statusCode,
          });
          res.destroy();
          req.destroy();
          finish(failure);
          return;
        }
        const chunks = [];
        let size = 0;
        res.on('data', chunk => {
          size += chunk.length;
          if (size > MAX_BODY) {
            const failure = error('response_too_large', 'control response exceeded body limit', {
              outcome: 'unknown', requestSha256,
            });
            res.destroy();
            req.destroy();
            finish(failure);
            return;
          }
          chunks.push(chunk);
        });
        res.on('end', () => finish(null, Buffer.concat(chunks, size)));
        res.on('aborted', () => finish(error('transport_error', 'control response was aborted', {
          outcome: 'unknown', requestSha256,
        })));
        res.on('error', () => finish(error('transport_error', 'control response failed', {
          outcome: 'unknown', requestSha256,
        })));
      });
    } catch {
      finish(error('transport_error', 'control request could not be started', {
        outcome: 'unknown', requestSha256,
      }));
      return;
    }
    req.on('error', () => finish(error('transport_error', 'control request outcome is unknown', {
      outcome: 'unknown', requestSha256,
    })));
    const timeoutFailure = () => {
      finish(error('timeout', 'control request timed out; outcome unknown', {
        outcome: 'unknown', requestSha256,
      }));
      req.destroy();
    };
    req.setTimeout(REQUEST_TIMEOUT_MS, timeoutFailure);
    timer = setTimeout(timeoutFailure, REQUEST_TIMEOUT_MS);
    req.end(body);
  });
}

function parseSignedResponse(body, { serverKey, run, channelId, nonce, requestSha256, op, args }) {
  let envelope;
  let envelopeText;
  try {
    envelopeText = new TextDecoder('utf-8', { fatal: true }).decode(body);
    envelope = JSON.parse(envelopeText);
  } catch {
    throw error('invalid_response', 'control response envelope is malformed', { outcome: 'unknown', requestSha256 });
  }
  if (!exactKeys(envelope, ['payload', 'signature'])) {
    throw error('invalid_response', 'control response envelope has invalid fields', { outcome: 'unknown', requestSha256 });
  }
  let raw;
  let signature;
  try {
    raw = decodeBase64Url(envelope.payload, 'response payload');
    signature = decodeBase64Url(envelope.signature, 'response signature');
  } catch {
    throw error('invalid_response', 'control response envelope encoding is invalid', { outcome: 'unknown', requestSha256 });
  }
  if (raw.length > MAX_RAW || signature.length !== 64) {
    throw error('invalid_response', 'control response size or signature length is invalid', { outcome: 'unknown', requestSha256 });
  }
  let validSignature = false;
  try {
    validSignature = verify(null, Buffer.concat([RESPONSE_PREFIX, raw]), serverKey, signature);
  } catch {}
  if (!validSignature) {
    throw error('invalid_signature', 'control response signature is invalid', { outcome: 'unknown', requestSha256 });
  }
  let payload;
  try {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(raw);
    payload = JSON.parse(text);
    if (!Buffer.from(canonical(payload), 'utf8').equals(raw)) throw new TypeError('noncanonical');
  } catch {
    throw error('invalid_response', 'signed control payload is malformed or noncanonical', {
      outcome: 'unknown', requestSha256, authenticated: true,
    });
  }
  if (!exactKeys(payload, ['version', 'run', 'channelId', 'nonce', 'requestSha256', 'ok', 'result']) ||
      payload.version !== 1 || payload.run !== run || payload.channelId !== channelId ||
      payload.nonce !== nonce || payload.requestSha256 !== requestSha256 || typeof payload.ok !== 'boolean') {
    throw error('invalid_response', 'signed control payload does not match this request', {
      outcome: 'unknown', requestSha256, authenticated: true,
    });
  }
  if (payload.ok === false) {
    if (!exactKeys(payload.result, ['error']) || typeof payload.result.error !== 'string' ||
        !FAILURE_CODES.has(payload.result.error)) {
      throw error('invalid_response', 'signed control failure code is not allowlisted', {
        outcome: 'unknown', requestSha256, authenticated: true,
      });
    }
    throw error(payload.result.error, 'authenticated control failure; outcome requires reconciliation', {
      outcome: 'unknown', requestSha256, authenticated: true,
    });
  }
  if (op === 'echo') {
    if (!exactKeys(payload.result, ['challenge']) || payload.result.challenge !== args.challenge) {
      throw error('invalid_response', 'signed echo result does not match this request', {
        outcome: 'unknown', requestSha256, authenticated: true,
      });
    }
  } else if (op === 'compare') {
    if (!exactKeys(payload.result, ['senderGrant']) || !plainObject(payload.result.senderGrant)) {
      throw error('invalid_response', 'signed compare result has invalid fields', {
        outcome: 'unknown', requestSha256, authenticated: true,
      });
    }
  }
  return payload.result;
}

function isAllowedHost(host) {
  if (typeof host !== 'string' || !isIPv4(host)) return false;
  if (host === '127.0.0.1') return true;
  const octets = host.split('.').map(Number);
  return octets[0] === 10 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168);
}

export function createClient({ host, port, run, channelId, serverPublicKeySpki, identity }) {
  if (!isAllowedHost(host)) throw new TypeError('host must be a pinned RFC1918 IPv4 or 127.0.0.1');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new TypeError('port must be a valid TCP port');
  if (!ALLOWED_RUNS.has(run)) throw new TypeError('run must be j60-join-v10 or j61-created-v14');
  const channelBytes = decodeBase64Url(channelId, 'channelId');
  if (channelBytes.length !== 16) throw new TypeError('channelId must encode 16 bytes');
  const normalizedIdentity = normalizeIdentity(identity);
  const { key: serverKey } = loadEd25519Public(serverPublicKeySpki, 'server public key');
  let pending = null;
  let inFlight = false;

  async function request(op, args) {
    if (inFlight) throw error('request_in_flight', 'a control request is already in flight');
    if (pending) throw error('pending_unknown', 'an unresolved control request blocks new requests', {
      outcome: 'unknown', requestSha256: pending.requestSha256,
    });
    const safeArgs = requestArguments(op, args);
    const nonce = randomBytes(16).toString('base64url');
    const startAt = Date.now();
    const payload = {
      version: 1,
      run,
      channelId,
      op,
      nonce,
      expiresAtMillis: startAt + 8000,
      args: safeArgs,
    };
    const raw = Buffer.from(canonical(payload), 'utf8');
    if (raw.length > MAX_RAW) throw new RangeError('control request payload exceeds raw limit');
    const requestSha256 = createHash('sha256').update(raw).digest('hex');
    const signature = sign(null, Buffer.concat([REQUEST_PREFIX, raw]), normalizedIdentity.privateKey);
    const body = Buffer.from(JSON.stringify({
      payload: raw.toString('base64url'),
      signature: signature.toString('base64url'),
    }), 'utf8');
    if (body.length > MAX_BODY) throw new RangeError('control request envelope exceeds body limit');
    const record = { raw: Buffer.from(raw), body: Buffer.from(body), requestSha256, nonce, state: 'in-flight' };
    pending = record;
    inFlight = true;
    try {
      const responseBody = await postBody({ host, port, body, requestSha256 });
      const result = parseSignedResponse(responseBody, {
        serverKey, run, channelId, nonce, requestSha256, op, args: safeArgs,
      });
      pending = null;
      return Object.freeze({ result, elapsedMs: Date.now() - startAt });
    } catch (failure) {
      if (pending === record) record.state = 'unknown';
      if (failure instanceof DirectControlError) {
        if (!failure.requestSha256) failure.requestSha256 = requestSha256;
        throw failure;
      }
      throw error('outcome_unknown', 'control request outcome is unknown', {
        outcome: 'unknown', requestSha256,
      });
    } finally {
      inFlight = false;
    }
  }

  function resolveUnknown({ outcomeKnown } = {}) {
    if (inFlight) throw error('request_in_flight', 'cannot resolve an in-flight request');
    if (!pending || pending.state !== 'unknown') throw error('no_unknown_request', 'there is no unknown request to resolve');
    if (outcomeKnown !== true) throw error('operator_confirmation_required', 'operator must confirm the request outcome is known');
    pending = null;
  }

  return Object.freeze({
    request,
    resolveUnknown,
    get pending() {
      if (!pending) return null;
      return Object.freeze({
        state: pending.state,
        nonce: pending.nonce,
        requestSha256: pending.requestSha256,
        rawPayload: Buffer.from(pending.raw),
        requestBody: Buffer.from(pending.body),
      });
    },
  });
}
