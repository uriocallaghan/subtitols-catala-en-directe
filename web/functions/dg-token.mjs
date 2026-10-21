// Broker de tokens Deepgram: la clau real viu a DEEPGRAM_API_KEY (Netlify env).
// Retorna un token efímer (~120 s) que el navegador usa només per obrir el socket.
// Així l'àudio viatja directament navegador → Deepgram, sense passar per la funció.

const GRANT_URL = 'https://api.deepgram.com/v1/auth/grant';
const TOKEN_TTL = 120;              // segons: prou per obrir el socket, res més
const MAX_TOKENS_PER_HOUR = 30;     // fre anti-abús per IP (millor esforç)
const ALLOWED_HOSTS = [
  'asr.uriocallaghan.com',
  'catala-asr.netlify.app',
  'localhost',
  '127.0.0.1',
];

function isOwnSite(h) {
  // domini propi, el .netlify.app del lloc i les seves deploy previews
  return ALLOWED_HOSTS.includes(h) || h.endsWith('--catala-asr.netlify.app');
}

const hits = new Map(); // ip → { count, reset }

function limited(ip) {
  const now = Date.now();
  const e = hits.get(ip);
  if (!e || now > e.reset) {
    hits.set(ip, { count: 1, reset: now + 3_600_000 });
    return false;
  }
  e.count++;
  return e.count > MAX_TOKENS_PER_HOUR;
}

function hostAllowed(req) {
  // els navegadors marquen les crides incrustades des d'altres llocs
  const sfs = req.headers.get('sec-fetch-site');
  if (sfs === 'cross-site') return false;
  const ref = req.headers.get('origin') || req.headers.get('referer') || '';
  if (!ref) return sfs !== 'cross-site'; // curl/directe: ho cobreix el rate limit
  try {
    return isOwnSite(new URL(ref).hostname);
  } catch (_) {
    return false;
  }
}

export default async (req, context) => {
  if (!hostAllowed(req)) {
    return Response.json({ error: 'origin not allowed' }, { status: 403 });
  }
  const ip = req.headers.get('x-nf-client-connection-ip') || context.ip || 'anon';
  if (limited(ip)) {
    return Response.json({ error: 'rate limited' }, { status: 429 });
  }

  const key = process.env.DEEPGRAM_API_KEY;
  if (!key) {
    return Response.json({ error: 'server misconfigured' }, { status: 500 });
  }

  const res = await fetch(GRANT_URL, {
    method: 'POST',
    headers: {
      Authorization: `Token ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ ttl_seconds: TOKEN_TTL }),
  });

  if (!res.ok) {
    return Response.json({ error: 'grant failed', dgStatus: res.status }, { status: 502 });
  }
  const data = await res.json();
  return Response.json(
    { access_token: data.access_token, expires_in: data.expires_in || TOKEN_TTL },
    { headers: { 'Cache-Control': 'no-store' } }
  );
};

export const config = { path: '/.netlify/functions/dg-token' };
