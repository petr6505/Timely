// Timely sync backend (Cloudflare Worker + D1).
// Stores per-device daily usage chunks (gzip JSON), synced settings, and auth.

const PBKDF2_ITER = 100_000; // Workers WebCrypto max
const PAIR_TTL_MS = 10 * 60 * 1000;
const FULL_DETAIL_DAYS = 90;
const MAX_CHUNK_BYTES = 256 * 1024;
const MAX_SETTINGS_BYTES = 64 * 1024;
const PLATFORMS = new Set(['android', 'linux', 'windows']);

const enc = new TextEncoder();

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json', ...SEC_HEADERS, ...headers },
  });
}
const SEC_HEADERS = {
  'strict-transport-security': 'max-age=63072000; includeSubDomains',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'cache-control': 'no-store',
};
class HttpError extends Error {
  constructor(status, msg) { super(msg); this.status = status; }
}
const fail = (status, msg) => { throw new HttpError(status, msg); };

function b64(buf) {
  let s = '';
  const bytes = new Uint8Array(buf);
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function unb64(str) {
  const s = atob(str);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
function randomToken(bytes = 32) {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return b64(b).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function sha256(str) {
  return b64(await crypto.subtle.digest('SHA-256', enc.encode(str)));
}
async function pbkdf2(password, salt, iter) {
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter }, key, 256);
  return b64(bits);
}
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
const PAIR_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no 0/O/1/I/L
function pairCode() {
  const b = crypto.getRandomValues(new Uint8Array(8));
  let s = '';
  for (const x of b) s += PAIR_ALPHABET[x % PAIR_ALPHABET.length];
  return s.slice(0, 4) + '-' + s.slice(4);
}
const normCode = (c) => String(c || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

async function body(req) {
  try { return await req.json(); } catch { fail(400, 'invalid json'); }
}
function cleanName(n, fallback) {
  const s = String(n || '').trim().slice(0, 64);
  return s || fallback;
}
function checkPlatform(p) {
  if (!PLATFORMS.has(p)) fail(400, 'invalid platform');
  return p;
}

async function rateLimit(env, key, max, windowMs) {
  const now = Date.now();
  const row = await env.DB.prepare('SELECT count, window_start FROM rate_limits WHERE key = ?').bind(key).first();
  if (!row || now - row.window_start > windowMs) {
    await env.DB.prepare('INSERT OR REPLACE INTO rate_limits (key, count, window_start) VALUES (?, 1, ?)').bind(key, now).run();
    return;
  }
  if (row.count >= max) fail(429, 'too many attempts, try again later');
  await env.DB.prepare('UPDATE rate_limits SET count = count + 1 WHERE key = ?').bind(key).run();
}

// Signing in again from the same device (same name and platform, e.g. after a
// reinstall) reuses its id and only issues a new token, so history continues.
async function createDevice(env, userId, name, platform) {
  const token = randomToken();
  const now = Date.now();
  const existing = await env.DB.prepare('SELECT id FROM devices WHERE user_id = ? AND name = ? AND platform = ?')
    .bind(userId, name, platform).first();
  if (existing) {
    await env.DB.prepare('UPDATE devices SET token_hash = ?, last_seen = ? WHERE id = ?')
      .bind(await sha256(token), now, existing.id).run();
    return { token, deviceId: existing.id };
  }
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO devices (id, user_id, name, platform, token_hash, created_at, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?)'
  ).bind(id, userId, name, platform, await sha256(token), now, now).run();
  return { token, deviceId: id };
}

async function auth(req, env) {
  const h = req.headers.get('authorization') || '';
  const m = h.match(/^Bearer ([A-Za-z0-9_-]{20,})$/);
  if (!m) fail(401, 'unauthorized');
  const dev = await env.DB.prepare('SELECT id, user_id, last_seen FROM devices WHERE token_hash = ?')
    .bind(await sha256(m[1])).first();
  if (!dev) fail(401, 'unauthorized');
  const now = Date.now();
  if (now - dev.last_seen > 60_000) {
    await env.DB.prepare('UPDATE devices SET last_seen = ? WHERE id = ?').bind(now, dev.id).run();
  }
  return { userId: dev.user_id, deviceId: dev.id };
}

async function register(req, env) {
  const ip = req.headers.get('cf-connecting-ip') || 'x';
  await rateLimit(env, 'reg:' + ip, 5, 60 * 60 * 1000);
  const { email, password, deviceName, platform } = await body(req);
  const em = String(email || '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(em) || em.length > 254) fail(400, 'invalid email');
  if (typeof password !== 'string' || password.length < 10 || password.length > 256) fail(400, 'password must be at least 10 characters');
  checkPlatform(platform);
  if (await env.DB.prepare('SELECT 1 FROM users WHERE email = ?').bind(em).first()) fail(409, 'account already exists');
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const userId = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id, email, pw_hash, pw_salt, pw_iter, created_at) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(userId, em, await pbkdf2(password, salt, PBKDF2_ITER), b64(salt), PBKDF2_ITER, Date.now()).run();
  return json(await createDevice(env, userId, cleanName(deviceName, platform), platform), 201);
}

async function login(req, env) {
  const ip = req.headers.get('cf-connecting-ip') || 'x';
  const { email, password, deviceName, platform } = await body(req);
  const em = String(email || '').trim().toLowerCase();
  checkPlatform(platform);
  await rateLimit(env, 'login-ip:' + ip, 20, 15 * 60 * 1000);
  await rateLimit(env, 'login:' + em, 10, 15 * 60 * 1000);
  const u = await env.DB.prepare('SELECT id, pw_hash, pw_salt, pw_iter FROM users WHERE email = ?').bind(em).first();
  // Always run PBKDF2 so response time does not reveal whether the account exists.
  const salt = u ? unb64(u.pw_salt) : new Uint8Array(16);
  const hash = await pbkdf2(String(password || ''), salt, u ? u.pw_iter : PBKDF2_ITER);
  if (!u || !timingSafeEqual(hash, u.pw_hash)) fail(401, 'wrong email or password');
  return json(await createDevice(env, u.id, cleanName(deviceName, platform), platform));
}

async function pairCreate(req, env, a) {
  // clear expired codes opportunistically
  await env.DB.prepare('DELETE FROM pair_codes WHERE expires_at < ?').bind(Date.now()).run();
  const code = pairCode();
  const expiresAt = Date.now() + PAIR_TTL_MS;
  await env.DB.prepare('INSERT INTO pair_codes (code_hash, user_id, expires_at) VALUES (?, ?, ?)')
    .bind(await sha256(normCode(code)), a.userId, expiresAt).run();
  const origin = new URL(req.url).origin;
  return json({ code, expiresAt, link: `${origin}/p/${code}`, appLink: `timely://pair?s=${encodeURIComponent(origin)}&c=${code}` });
}

async function pairRedeem(req, env) {
  const ip = req.headers.get('cf-connecting-ip') || 'x';
  await rateLimit(env, 'pair:' + ip, 20, 15 * 60 * 1000);
  const { code, deviceName, platform } = await body(req);
  checkPlatform(platform);
  const h = await sha256(normCode(code));
  // single use: delete and read in one statement
  const row = await env.DB.prepare('DELETE FROM pair_codes WHERE code_hash = ? RETURNING user_id, expires_at').bind(h).first();
  if (!row || row.expires_at < Date.now()) fail(400, 'invalid or expired code');
  return json(await createDevice(env, row.user_id, cleanName(deviceName, platform), platform), 201);
}

async function listDevices(env, a) {
  const { results } = await env.DB.prepare(
    'SELECT id, name, platform, created_at AS createdAt, last_seen AS lastSeen FROM devices WHERE user_id = ? ORDER BY created_at'
  ).bind(a.userId).all();
  return json({ devices: results, self: a.deviceId });
}

async function patchDevice(req, env, a, id) {
  const { name } = await body(req);
  const r = await env.DB.prepare('UPDATE devices SET name = ? WHERE id = ? AND user_id = ?')
    .bind(cleanName(name, 'device'), id, a.userId).run();
  if (!r.meta.changes) fail(404, 'not found');
  return json({ ok: true });
}

// With ?purge=1 this also deletes the device's history. That works for devices
// that were already removed too, so leftover data can be cleaned up.
async function deleteDevice(req, env, a, id) {
  const purge = new URL(req.url).searchParams.get('purge') === '1';
  const r = await env.DB.prepare('DELETE FROM devices WHERE id = ? AND user_id = ?').bind(id, a.userId).run();
  let purged = 0;
  if (purge) {
    const c = await env.DB.prepare('DELETE FROM chunks WHERE device_id = ? AND user_id = ?').bind(id, a.userId).run();
    purged = c.meta.changes;
  }
  if (!r.meta.changes && !purged) fail(404, 'not found');
  return json({ ok: true });
}

async function putChunk(req, env, a, day) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) fail(400, 'invalid day');
  const data = new Uint8Array(await req.arrayBuffer());
  if (data.length === 0 || data.length > MAX_CHUNK_BYTES) fail(413, 'chunk too large');
  if (data[0] !== 0x1f || data[1] !== 0x8b) fail(400, 'chunk must be gzip');
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO chunks (user_id, device_id, day, kind, data, updated_at) VALUES (?, ?, ?, 0, ?, ?)
     ON CONFLICT(device_id, day) DO UPDATE SET data = excluded.data, kind = 0, updated_at = excluded.updated_at`
  ).bind(a.userId, a.deviceId, day, data, now).run();
  return json({ ok: true, updatedAt: now });
}

async function getChunks(req, env, a) {
  const u = new URL(req.url);
  const since = Number(u.searchParams.get('since') || 0);
  const limit = 200;
  const { results } = await env.DB.prepare(
    `SELECT device_id AS deviceId, day, kind, data, updated_at AS updatedAt FROM chunks
     WHERE user_id = ? AND updated_at > ? ORDER BY updated_at LIMIT ?`
  ).bind(a.userId, since, limit).all();
  const chunks = results.map((r) => ({ ...r, data: b64(r.data) }));
  return json({ chunks, more: chunks.length === limit });
}

async function getSettings(env, a) {
  const r = await env.DB.prepare('SELECT data, updated_at FROM settings WHERE user_id = ?').bind(a.userId).first();
  return json(r ? { data: JSON.parse(r.data), updatedAt: r.updated_at } : { data: null, updatedAt: 0 });
}

async function putSettings(req, env, a) {
  const text = await req.text();
  if (text.length > MAX_SETTINGS_BYTES) fail(413, 'settings too large');
  let parsed;
  try { parsed = JSON.parse(text); } catch { fail(400, 'invalid json'); }
  if (!parsed || typeof parsed.data !== 'object') fail(400, 'missing data');
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO settings (user_id, data, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at`
  ).bind(a.userId, JSON.stringify(parsed.data), now).run();
  return json({ ok: true, updatedAt: now });
}

async function deleteAccount(req, env, a) {
  const { password } = await body(req);
  const u = await env.DB.prepare('SELECT pw_hash, pw_salt, pw_iter FROM users WHERE id = ?').bind(a.userId).first();
  const hash = await pbkdf2(String(password || ''), unb64(u.pw_salt), u.pw_iter);
  if (!timingSafeEqual(hash, u.pw_hash)) fail(401, 'wrong password');
  await env.DB.batch([
    env.DB.prepare('DELETE FROM chunks WHERE user_id = ?').bind(a.userId),
    env.DB.prepare('DELETE FROM settings WHERE user_id = ?').bind(a.userId),
    env.DB.prepare('DELETE FROM pair_codes WHERE user_id = ?').bind(a.userId),
    env.DB.prepare('DELETE FROM devices WHERE user_id = ?').bind(a.userId),
    env.DB.prepare('DELETE FROM users WHERE id = ?').bind(a.userId),
  ]);
  return json({ ok: true });
}

function pairPage(req, code) {
  const origin = new URL(req.url).origin;
  const safe = normCode(code).slice(0, 8);
  const pretty = safe.slice(0, 4) + '-' + safe.slice(4);
  const app = `timely://pair?s=${encodeURIComponent(origin)}&c=${pretty}`;
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Timely pairing</title>
<style>body{background:#111;color:#e8e6e3;font:16px/1.6 ui-monospace,monospace;max-width:28rem;margin:4rem auto;padding:0 1rem}
a{color:#ffb000}code{font-size:2rem;letter-spacing:.2em;display:block;margin:1rem 0}</style>
<p>timely / add device</p><code>${pretty}</code>
<p><a href="${app}">open in timely &rarr;</a></p>
<p>or open Timely on the new device, choose <em>pair with code</em> and enter the code above together with server <br><small>${origin}</small></p>
<p><small>code is valid for 10 minutes and works once.</small></p>`;
  return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', ...SEC_HEADERS } });
}

async function gunzip(bytes) {
  // D1 returns BLOB columns as plain number arrays
  const s = new Blob([bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Response(s).text();
}
async function gzip(text) {
  const s = new Blob([enc.encode(text)]).stream().pipeThrough(new CompressionStream('gzip'));
  return new Uint8Array(await new Response(s).arrayBuffer());
}
// sessions [app, startDelta, dur, ...] -> hourly [app, hour, secs, ...]
export function toHourly(flat) {
  const acc = new Map();
  let start = 0;
  for (let i = 0; i + 2 < flat.length; i += 3) {
    const app = flat[i];
    start += flat[i + 1];
    let s = start, rem = flat[i + 2];
    while (rem > 0) {
      const hour = Math.floor(s / 3600);
      const take = Math.min(rem, (hour + 1) * 3600 - s);
      const k = app * 100 + hour;
      acc.set(k, (acc.get(k) || 0) + take);
      s += take; rem -= take;
    }
  }
  const out = [];
  for (const k of [...acc.keys()].sort((a, b) => a - b)) out.push(Math.floor(k / 100), k % 100, acc.get(k));
  return out;
}
async function rollup(env) {
  const cutoff = new Date(Date.now() - FULL_DETAIL_DAYS * 86400_000).toISOString().slice(0, 10);
  for (let round = 0; round < 10; round++) {
    const { results } = await env.DB.prepare('SELECT device_id, day, data FROM chunks WHERE kind = 0 AND day < ? LIMIT 50')
      .bind(cutoff).all();
    if (!results.length) return;
    const stmts = [];
    for (const r of results) {
      let c;
      try {
        c = JSON.parse(await gunzip(r.data));
      } catch (e) {
        console.error('rollup: unreadable chunk', r.device_id, r.day, e);
        continue;
      }
      const h = { v: 1, d: c.d, z: c.z, a: c.a, hf: toHourly(c.f || []), hm: toHourly(c.m || []), u: c.u };
      stmts.push(env.DB.prepare('UPDATE chunks SET kind = 1, data = ?, updated_at = ? WHERE device_id = ? AND day = ?')
        .bind(await gzip(JSON.stringify(h)), Date.now(), r.device_id, r.day));
    }
    await env.DB.batch(stmts);
  }
}

async function route(req, env) {
  const url = new URL(req.url);
  const p = url.pathname;
  const m = req.method;
  if (url.protocol !== 'https:' && url.hostname !== 'localhost' && url.hostname !== '127.0.0.1') fail(400, 'https required');

  if (m === 'GET' && p === '/') return json({ service: 'timely', ok: true });
  if (m === 'GET' && p.startsWith('/p/')) return pairPage(req, p.slice(3));
  if (m === 'POST' && p === '/v1/register') return register(req, env);
  if (m === 'POST' && p === '/v1/login') return login(req, env);
  if (m === 'POST' && p === '/v1/pair/redeem') return pairRedeem(req, env);

  const a = await auth(req, env);
  if (m === 'POST' && p === '/v1/pair/create') return pairCreate(req, env, a);
  if (m === 'GET' && p === '/v1/devices') return listDevices(env, a);
  let mm;
  if ((mm = p.match(/^\/v1\/devices\/([0-9a-f-]{36})$/))) {
    if (m === 'PATCH') return patchDevice(req, env, a, mm[1]);
    if (m === 'DELETE') return deleteDevice(req, env, a, mm[1]);
  }
  if (m === 'PUT' && (mm = p.match(/^\/v1\/chunks\/(.+)$/))) return putChunk(req, env, a, mm[1]);
  if (m === 'GET' && p === '/v1/chunks') return getChunks(req, env, a);
  if (m === 'GET' && p === '/v1/settings') return getSettings(env, a);
  if (m === 'PUT' && p === '/v1/settings') return putSettings(req, env, a);
  if (m === 'POST' && p === '/v1/logout') {
    // revoke the token but keep the device so its history stays attached
    await env.DB.prepare('UPDATE devices SET token_hash = ? WHERE id = ?')
      .bind(await sha256(randomToken()), a.deviceId).run();
    return json({ ok: true });
  }
  if (m === 'POST' && p === '/v1/account/delete') return deleteAccount(req, env, a);
  fail(404, 'not found');
}

export default {
  async fetch(req, env) {
    try {
      return await route(req, env);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error(e);
      return json({ error: 'internal error' }, 500);
    }
  },
  async scheduled(_evt, env, ctx) {
    ctx.waitUntil(Promise.all([
      rollup(env),
      env.DB.prepare('DELETE FROM pair_codes WHERE expires_at < ?').bind(Date.now()).run(),
      env.DB.prepare('DELETE FROM rate_limits WHERE window_start < ?').bind(Date.now() - 86400_000).run(),
    ]));
  },
};
