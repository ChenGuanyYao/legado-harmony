import {
  X509Certificate,
  createHash,
  timingSafeEqual
} from 'node:crypto';
import { readFile } from 'node:fs/promises';
import {
  SignJWT,
  compactVerify,
  decodeProtectedHeader,
  importPKCS8
} from 'jose';
import { config, readSecretFile } from './config.js';

interface PurchaseData {
  jwsPurchaseOrder?: string;
}

export interface PurchaseOrderPayload {
  environment?: string;
  applicationId?: string;
  packageName?: string;
  productId?: string;
  productType?: string | number;
  purchaseOrderId?: string;
  purchaseToken?: string;
  purchaseState?: string | number;
  purchaseStatus?: string | number;
  status?: string | number;
  finishStatus?: string | number;
  purchaseTime?: number;
}

interface OrderStatusResponse {
  responseCode?: string;
  responseMessage?: string;
  jwsPurchaseOrder?: string;
}

const PRODUCT_POINTS = new Map<string, number>([
  ['legado_points_10', 10],
  ['legado_points_60', 60],
  ['legado_points_100', 100],
  ['legado_points_300', 300],
  ['legado_points_500', 500],
  ['legado_points_1000', 1000]
]);
let privateKeyPromise: ReturnType<typeof importPKCS8> | null = null;
let pinnedRootPromise: Promise<X509Certificate> | null = null;

export function pointsForProduct(productId: string): number {
  const points = PRODUCT_POINTS.get(productId);
  if (!points) {
    throw new Error('Unknown IAP product');
  }
  return points;
}

export async function verifyPurchaseData(purchaseDataRaw: string): Promise<PurchaseOrderPayload> {
  let purchaseData: PurchaseData;
  try {
    purchaseData = JSON.parse(purchaseDataRaw) as PurchaseData;
  } catch {
    throw new Error('Malformed purchaseData');
  }
  if (!purchaseData.jwsPurchaseOrder) {
    throw new Error('Missing jwsPurchaseOrder');
  }

  // Verify the device result first so untrusted values are never used as authoritative data.
  const devicePayload = await verifyHuaweiJws(purchaseData.jwsPurchaseOrder);
  requireOrderIdentity(devicePayload);

  // Query Huawei's server for the latest state and verify that independently signed response.
  const payload = await queryHuaweiPurchaseOrder(
    devicePayload.purchaseOrderId!,
    devicePayload.purchaseToken!
  );
  if (payload.purchaseOrderId !== devicePayload.purchaseOrderId ||
    payload.purchaseToken !== devicePayload.purchaseToken) {
    throw new Error('Huawei order identity mismatch');
  }
  if (payload.productId !== devicePayload.productId) {
    throw new Error('Huawei order product mismatch');
  }
  if (payload.applicationId && payload.applicationId !== config.huaweiAppId) {
    throw new Error('Huawei order application mismatch');
  }
  if (payload.packageName && payload.packageName !== config.huaweiBundleName) {
    throw new Error('Huawei order package mismatch');
  }
  ensureDeliverableState(payload);
  pointsForProduct(payload.productId!);
  return payload;
}

export async function queryHuaweiPurchaseOrder(
  purchaseOrderId: string,
  purchaseToken: string
): Promise<PurchaseOrderPayload> {
  const requestBody = JSON.stringify({ purchaseOrderId, purchaseToken });
  const authorization = await createIapAuthorization(requestBody);
  const response = await fetch(
    `${config.iapRootUrl}/order/harmony/v1/application/order/status/query`,
    {
      method: 'POST',
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json;charset=UTF-8',
        'Authorization': `Bearer ${authorization}`
      },
      body: requestBody,
      signal: AbortSignal.timeout(config.http.upstreamTimeoutMs)
    }
  );
  let orderStatus: OrderStatusResponse;
  try {
    orderStatus = await response.json() as OrderStatusResponse;
  } catch {
    throw new Error('Huawei IAP returned an invalid response');
  }
  if (!response.ok || orderStatus.responseCode !== '0' || !orderStatus.jwsPurchaseOrder) {
    throw new Error('Huawei IAP order status query failed');
  }
  const payload = await verifyHuaweiJws(orderStatus.jwsPurchaseOrder);
  requireOrderIdentity(payload);
  if (payload.purchaseOrderId !== purchaseOrderId || payload.purchaseToken !== purchaseToken) {
    throw new Error('Huawei order identity mismatch');
  }
  return payload;
}

async function createIapAuthorization(body: string): Promise<string> {
  privateKeyPromise ||= readSecretFile(config.iapPrivateKeyPath)
    .then((privateKeyPem) => importPKCS8(privateKeyPem, 'ES256'));
  const privateKey = await privateKeyPromise;
  const now = Math.floor(Date.now() / 1000);
  const digest = createHash('sha256').update(body, 'utf8').digest('hex');
  return new SignJWT({
    iss: config.iapIssuerId,
    aud: 'iap-v1',
    iat: now,
    exp: now + 3600,
    aid: config.huaweiAppId,
    digest
  })
    .setProtectedHeader({ alg: 'ES256', typ: 'JWT', kid: config.iapKeyId })
    .sign(privateKey);
}

async function verifyHuaweiJws(jws: string): Promise<PurchaseOrderPayload> {
  const header = decodeProtectedHeader(jws);
  if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length !== 3) {
    throw new Error('Invalid Huawei IAP JWS header');
  }
  const certificates = header.x5c.map((encoded) =>
    new X509Certificate(Buffer.from(encoded, 'base64')));
  const leaf = certificates[0]!;
  const intermediate = certificates[1]!;
  const suppliedRoot = certificates[2]!;
  pinnedRootPromise ||= readFile(config.iapRootCaPath)
    .then((value) => new X509Certificate(value));
  const pinnedRoot = await pinnedRootPromise;
  const now = Date.now();
  for (const certificate of certificates) {
    if (now < Date.parse(certificate.validFrom) || now > Date.parse(certificate.validTo)) {
      throw new Error('Expired Huawei IAP signing certificate');
    }
  }
  if (!leaf.verify(intermediate.publicKey) ||
    !intermediate.verify(suppliedRoot.publicKey) ||
    !suppliedRoot.verify(suppliedRoot.publicKey)) {
    throw new Error('Invalid Huawei IAP certificate chain');
  }
  if (!sameBuffer(suppliedRoot.raw, pinnedRoot.raw)) {
    throw new Error('Untrusted Huawei IAP root certificate');
  }
  const verified = await compactVerify(jws, leaf.publicKey);
  return JSON.parse(new TextDecoder().decode(verified.payload)) as PurchaseOrderPayload;
}

function sameBuffer(left: Buffer, right: Buffer): boolean {
  return left.length === right.length && timingSafeEqual(left, right);
}

function requireOrderIdentity(payload: PurchaseOrderPayload): void {
  if (!payload.productId || !payload.purchaseOrderId || !payload.purchaseToken) {
    throw new Error('Incomplete Huawei purchase order');
  }
}

export function purchaseState(payload: PurchaseOrderPayload): string {
  return String(payload.purchaseState ?? payload.purchaseStatus ?? payload.status ?? '')
    .trim()
    .toUpperCase();
}

export function isRevokedPurchaseState(payload: PurchaseOrderPayload): boolean {
  return config.iap.revocationStatuses.has(purchaseState(payload));
}

export function isDeliverablePurchaseState(payload: PurchaseOrderPayload): boolean {
  const value = purchaseState(payload);
  return Boolean(value && config.iap.deliverableStatuses.has(value));
}

function ensureDeliverableState(payload: PurchaseOrderPayload): void {
  if (!isDeliverablePurchaseState(payload)) {
    throw new Error('Huawei order is not in a deliverable state');
  }
}
