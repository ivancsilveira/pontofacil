// ============================================================
// rekognition.js — chamadas puras ao AWS Rekognition
// Sem HTTP, sem validação de formato. Só AWS SDK.
// ============================================================
const {
  RekognitionClient,
  IndexFacesCommand,
  SearchFacesByImageCommand,
  DeleteFacesCommand,
  ListFacesCommand,
} = require('@aws-sdk/client-rekognition');

const COLLECTION_ID = process.env.COLLECTION_ID || 'pontofacil-rostos';
const REGION = process.env.AWS_REGION || 'sa-east-1';

const client = new RekognitionClient({ region: REGION });

/**
 * Indexa um rosto na collection.
 * @param {Buffer} imageBytes — imagem JPEG/PNG decodificada
 * @param {string} externalImageId — ID do funcionário (fica em Face.ExternalImageId)
 * @returns {Promise<{ok: boolean, faceId?: string, confidence?: number, unindexed?: Array}>}
 */
async function indexFace(imageBytes, externalImageId) {
  // LGPD: antes de indexar, apaga qualquer face existente com o mesmo externalImageId.
  // Garante 1 face por funcionário, evita lixo.
  try {
    const list = await client.send(new ListFacesCommand({
      CollectionId: COLLECTION_ID,
      MaxResults: 100,  // escala atual: ~18 funcs, margem confortável
    }));
    const staleIds = (list.Faces || [])
      .filter(f => f.ExternalImageId === externalImageId)
      .map(f => f.FaceId);
    if (staleIds.length) {
      await client.send(new DeleteFacesCommand({
        CollectionId: COLLECTION_ID,
        FaceIds: staleIds,
      }));
      console.log(JSON.stringify({
        ts: new Date().toISOString(),
        action: 'index_dedup_cleanup',
        externalImageId,
        deletedCount: staleIds.length,
        deletedIds: staleIds,
      }));
    }
  } catch (e) {
    console.warn('indexFace dedup cleanup failed (non-fatal):', e.message);
  }

  const result = await client.send(new IndexFacesCommand({
    CollectionId: COLLECTION_ID,
    Image: { Bytes: imageBytes },
    ExternalImageId: externalImageId,
    DetectionAttributes: [],  // não pede atributos extras — economia
    MaxFaces: 1,              // só 1 rosto por imagem no cadastro
    QualityFilter: 'AUTO',    // Rekognition descarta rostos de baixa qualidade
  }));

  const record = result.FaceRecords?.[0];
  if (!record) {
    return {
      ok: false,
      unindexed: (result.UnindexedFaces || []).map(u => ({ reasons: u.Reasons })),
    };
  }
  return {
    ok: true,
    faceId: record.Face.FaceId,
    confidence: record.Face.Confidence,
  };
}

/**
 * Busca um rosto parecido na collection.
 * @param {Buffer} imageBytes — imagem da pessoa tentando logar
 * @param {number} threshold — similaridade mínima (0-100). Default 80.
 * @returns {Promise<{ok: true, matches: Array, searchedFaceConfidence?: number, reason?: string}>}
 */
async function searchFace(imageBytes, threshold = 80) {
  try {
    const result = await client.send(new SearchFacesByImageCommand({
      CollectionId: COLLECTION_ID,
      Image: { Bytes: imageBytes },
      FaceMatchThreshold: threshold,
      MaxFaces: 3,  // top 3 — client escolhe melhor e mostra margem
      QualityFilter: 'AUTO',
    }));
    const matches = (result.FaceMatches || []).map(m => ({
      faceId: m.Face.FaceId,
      externalImageId: m.Face.ExternalImageId,
      similarity: m.Similarity,
    }));
    return {
      ok: true,
      matches,
      searchedFaceConfidence: result.SearchedFaceConfidence,
    };
  } catch (e) {
    // Rekognition lança InvalidParameterException quando a imagem de busca
    // não tem rosto detectável. Tratamos como "sem matches", não erro 500.
    if (e.name === 'InvalidParameterException') {
      return { ok: true, matches: [], reason: 'no_face_in_input' };
    }
    throw e;
  }
}

/**
 * Remove um rosto da collection (LGPD — direito ao esquecimento).
 * @param {string} faceId — ID do rosto (uuid)
 * @returns {Promise<{deleted: number, faceIds: string[]}>}
 */
async function deleteFace(faceId) {
  const result = await client.send(new DeleteFacesCommand({
    CollectionId: COLLECTION_ID,
    FaceIds: [faceId],
  }));
  return {
    deleted: (result.DeletedFaces || []).length,
    faceIds: result.DeletedFaces || [],
  };
}

module.exports = { indexFace, searchFace, deleteFace };
