// ============================================================
// index.js — handler Lambda (API Gateway REST integration)
// Router + CORS + validação de entrada + log de auditoria LGPD
// ============================================================
const rek = require('./rekognition');

// Suporta múltiplos origins (CSV em env var). Default = apenas GitHub Pages.
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || 'https://ivancsilveira.github.io')
  .split(',').map(s => s.trim()).filter(Boolean);

const MAX_IMAGE_BYTES = 4_500_000;
const FACE_ID_RE = /^[a-f0-9-]{36}$/;
const EXTID_RE = /^[a-zA-Z0-9_.\-:]{1,255}$/;

function pickCorsOrigin(event){
  const o = event.headers?.origin || event.headers?.Origin || '';
  return ALLOWED_ORIGINS.includes(o) ? o : ALLOWED_ORIGINS[0];
}

function makeHeaders(origin){
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'Content-Type, X-Api-Key',
    'Access-Control-Allow-Methods': 'POST, DELETE, OPTIONS',
    'Content-Type': 'application/json',
  };
}

function respond(statusCode, body, origin){
  return { statusCode, headers: makeHeaders(origin), body: JSON.stringify(body) };
}


function parseBody(event) {
  if (!event.body) return {};
  try {
    return event.isBase64Encoded
      ? JSON.parse(Buffer.from(event.body, 'base64').toString('utf8'))
      : JSON.parse(event.body);
  } catch {
    return null;
  }
}

function decodeImage(b64) {
  if (typeof b64 !== 'string' || !b64.length) return null;
  const clean = b64.includes(',') ? b64.split(',', 2)[1] : b64;
  try {
    const buf = Buffer.from(clean, 'base64');
    return buf.length > 0 ? buf : null;
  } catch {
    return null;
  }
}

function audit(obj) {
  // JSON estruturado para CloudWatch Insights + auditoria LGPD
  console.log(JSON.stringify({ ts: new Date().toISOString(), ...obj }));
}

exports.handler = async (event) => {
  const method = event.httpMethod;
  const route = event.resource;
  const origin = event.headers?.origin || event.headers?.Origin || '';
  const sourceIp = event.requestContext?.identity?.sourceIp || '-';
  const corsOrigin = pickCorsOrigin(event);
  const bodyLen = event.body ? event.body.length : 0;
  const bodyPreview = event.body ? event.body.slice(0, 80).replace(/[\r\n]/g,' ') : '';

  // Audit sempre que chega uma request (cria trail do que o Lambda viu)
  audit({
    action: 'request_received',
    method, route, origin, sourceIp,
    bodyLen, bodyPreview,
    hasApiKey: !!(event.headers?.['x-api-key'] || event.headers?.['X-Api-Key']),
    allowedOrigins: ALLOWED_ORIGINS,
  });

  if (method === 'OPTIONS') return respond(200, { ok: true }, corsOrigin);

  if (origin && !ALLOWED_ORIGINS.includes(origin)) {
    audit({ action: 'blocked_origin', origin, sourceIp, route });
    return respond(403, { error: 'origin_not_allowed' }, corsOrigin);
  }

  try {
    if (route === '/face/index' && method === 'POST') return await handleIndex(event, sourceIp, corsOrigin);
    if (route === '/face/search' && method === 'POST') return await handleSearch(event, sourceIp, corsOrigin);
    if (route === '/face/{faceId}' && method === 'DELETE') return await handleDelete(event, sourceIp, corsOrigin);
    return respond(404, { error: 'not_found' }, corsOrigin);
  } catch (err) {
    audit({ action: 'unhandled_error', name: err.name, message: err.message, route, sourceIp });
    return respond(500, { error: 'internal_error' }, corsOrigin);
  }
};

async function handleIndex(event, sourceIp, corsOrigin) {
  const body = parseBody(event);
  if (!body) {
    audit({ action: 'index_invalid_json', sourceIp, bodyRawLen: event.body?.length || 0 });
    return respond(400, { error: 'invalid_json' }, corsOrigin);
  }
  const imgField = body.imageBase64 || '';
  audit({
    action: 'index_received',
    sourceIp,
    externalImageId: body.externalImageId,
    imgBase64Len: imgField.length,
    imgBase64Head: imgField.slice(0, 50),
    imgBase64Tail: imgField.slice(-20),
  });

  const { imageBase64, externalImageId } = body;
  if (!imageBase64 || !externalImageId) {
    return respond(400, { error: 'missing_fields', required: ['imageBase64', 'externalImageId'] }, corsOrigin);
  }
  if (!EXTID_RE.test(externalImageId)) {
    return respond(400, { error: 'invalid_external_image_id', hint: 'chars permitidos: A-Z a-z 0-9 _ . - :' }, corsOrigin);
  }
  const image = decodeImage(imageBase64);
  if (!image) return respond(400, { error: 'invalid_image' }, corsOrigin);
  if (image.length > MAX_IMAGE_BYTES) return respond(413, { error: 'image_too_large', maxBytes: MAX_IMAGE_BYTES }, corsOrigin);

  const result = await rek.indexFace(image, externalImageId);
  if (!result.ok) {
    audit({ action: 'index_no_face', externalImageId, unindexedCount: result.unindexed.length, sourceIp });
    return respond(422, { error: 'no_face_detected', reasons: result.unindexed }, corsOrigin);
  }
  audit({ action: 'index_ok', externalImageId, faceId: result.faceId, confidence: result.confidence, sourceIp });
  return respond(200, { faceId: result.faceId, externalImageId, confidence: result.confidence }, corsOrigin);
}

async function handleSearch(event, sourceIp, corsOrigin) {
  const body = parseBody(event);
  if (!body) {
    audit({ action: 'search_invalid_json', sourceIp });
    return respond(400, { error: 'invalid_json' }, corsOrigin);
  }
  const imgField = body.imageBase64 || '';
  audit({
    action: 'search_received',
    sourceIp,
    imgBase64Len: imgField.length,
    imgBase64Head: imgField.slice(0, 50),
  });

  const { imageBase64, threshold } = body;
  if (!imageBase64) return respond(400, { error: 'missing_fields', required: ['imageBase64'] }, corsOrigin);
  const image = decodeImage(imageBase64);
  if (!image) return respond(400, { error: 'invalid_image' }, corsOrigin);
  if (image.length > MAX_IMAGE_BYTES) return respond(413, { error: 'image_too_large', maxBytes: MAX_IMAGE_BYTES }, corsOrigin);

  const t = typeof threshold === 'number' && threshold >= 0 && threshold <= 100 ? threshold : 80;
  const result = await rek.searchFace(image, t);
  audit({
    action: 'search_ok',
    matchCount: result.matches.length,
    topSimilarity: result.matches[0]?.similarity,
    topExternalImageId: result.matches[0]?.externalImageId,
    threshold: t,
    reason: result.reason,
    sourceIp,
  });
  return respond(200, {
    matches: result.matches,
    searchedFaceConfidence: result.searchedFaceConfidence,
    reason: result.reason,
  }, corsOrigin);
}

async function handleDelete(event, sourceIp, corsOrigin) {
  const faceId = event.pathParameters?.faceId;
  if (!faceId) return respond(400, { error: 'missing_face_id' }, corsOrigin);
  if (!FACE_ID_RE.test(faceId)) return respond(400, { error: 'invalid_face_id' }, corsOrigin);
  const result = await rek.deleteFace(faceId);
  audit({ action: 'delete_ok', faceId, deleted: result.deleted, sourceIp });
  return respond(200, { deleted: result.deleted, faceId }, corsOrigin);
}
