import { config } from './config.js';
import { inTransaction, pool } from './db.js';
import {
  isRevokedPurchaseState,
  purchaseState,
  queryHuaweiPurchaseOrder
} from './iap.js';

interface ReconciliationOrder {
  purchase_order_id: string;
  purchase_token: string;
}

export function calculateIapReversal(
  creditedPoints: number,
  originalDebtOffset: number,
  currentPaidBalance: number
): { reversedPoints: number; debtPoints: number } {
  const originallyAvailablePoints = Math.max(0, creditedPoints - originalDebtOffset);
  const reversedPoints = Math.min(Math.max(0, currentPaidBalance), originallyAvailablePoints);
  return {
    reversedPoints,
    debtPoints: originalDebtOffset + originallyAvailablePoints - reversedPoints
  };
}

export async function reconcileIapOrders(): Promise<{ checked: number; reversed: number }> {
  const lockClient = await pool.connect();
  try {
    const lock = await lockClient.query<{ acquired: boolean }>(
      `SELECT pg_try_advisory_lock(hashtextextended('iap-reconciliation', 0)) AS acquired`
    );
    if (!lock.rows[0]?.acquired) return { checked: 0, reversed: 0 };
    const pending = await pool.query<ReconciliationOrder>(
      `SELECT purchase_order_id, purchase_token
       FROM iap_orders
       WHERE reversed_at IS NULL
       ORDER BY COALESCE(last_checked_at, created_at), created_at
       LIMIT $1`,
      [Math.min(500, config.iap.reconciliationBatchSize)]
    );
    let checked = 0;
    let reversed = 0;
    for (const order of pending.rows) {
      try {
        const payload = await queryHuaweiPurchaseOrder(
          order.purchase_order_id,
          order.purchase_token
        );
        checked++;
        const state = purchaseState(payload) || 'UNKNOWN';
        if (isRevokedPurchaseState(payload)) {
          if (await reverseIapOrder(order.purchase_order_id, state)) reversed++;
        } else {
          await pool.query(
            `UPDATE iap_orders
             SET order_status = $2, last_checked_at = now(), verified_payload = $3::jsonb
             WHERE purchase_order_id = $1 AND reversed_at IS NULL`,
            [order.purchase_order_id, state, JSON.stringify(payload)]
          );
        }
      } catch {
        // A transient Huawei failure must not revoke value. It will be retried in the next batch.
        await pool.query(
          `UPDATE iap_orders
           SET last_checked_at = now()
           WHERE purchase_order_id = $1 AND reversed_at IS NULL`,
          [order.purchase_order_id]
        );
      }
    }
    return { checked, reversed };
  } finally {
    try {
      await lockClient.query(`SELECT pg_advisory_unlock(hashtextextended('iap-reconciliation', 0))`);
    } finally {
      lockClient.release();
    }
  }
}

async function reverseIapOrder(orderId: string, status: string): Promise<boolean> {
  return inTransaction(async (client) => {
    await client.query(
      'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
      [`iap:${orderId}`]
    );
    const order = await client.query<{
      user_id: string;
      credited_points: string;
      debt_offset_points: string;
      reversed_at: Date | null;
    }>(
      `SELECT user_id, credited_points, debt_offset_points, reversed_at
       FROM iap_orders
       WHERE purchase_order_id = $1
       FOR UPDATE`,
      [orderId]
    );
    if (!order.rowCount || order.rows[0]!.reversed_at) return false;
    const userId = order.rows[0]!.user_id;
    const creditedPoints = Number(order.rows[0]!.credited_points);
    const originalDebtOffset = Number(order.rows[0]!.debt_offset_points);
    const wallet = await client.query<{ balance: string; paid_balance: string }>(
      `SELECT balance, paid_balance
       FROM point_wallets
       WHERE user_id = $1
       FOR UPDATE`,
      [userId]
    );
    if (!wallet.rowCount) return false;
    const balance = Number(wallet.rows[0]!.balance);
    const paidBalance = Number(wallet.rows[0]!.paid_balance);
    const { reversedPoints, debtPoints } = calculateIapReversal(
      creditedPoints,
      originalDebtOffset,
      paidBalance
    );
    const balanceAfter = balance - reversedPoints;
    await client.query(
      `UPDATE point_wallets
       SET balance = $2, paid_balance = paid_balance - $3, updated_at = now()
       WHERE user_id = $1`,
      [userId, balanceAfter, reversedPoints]
    );
    await client.query(
      `INSERT INTO point_ledger (
         user_id, delta, balance_after, reason, reference_id, idempotency_key
       ) VALUES ($1, $2, $3, 'IAP_REVERSAL', $4, $5)
       ON CONFLICT (idempotency_key) DO NOTHING`,
      [userId, -reversedPoints, balanceAfter, orderId, `iap-reversal:${orderId}`]
    );
    if (debtPoints > 0) {
      await client.query(
        `INSERT INTO account_debts (user_id, iap_debt_points)
         VALUES ($1, $2)
         ON CONFLICT (user_id) DO UPDATE SET
           iap_debt_points = account_debts.iap_debt_points + EXCLUDED.iap_debt_points,
           updated_at = now()`,
        [userId, debtPoints]
      );
    }
    await client.query(
      `UPDATE iap_orders
       SET order_status = $2, last_checked_at = now(), reversed_at = now(),
           reversed_points = $3, debt_points = $4
       WHERE purchase_order_id = $1`,
      [orderId, status, reversedPoints, debtPoints]
    );
    return true;
  });
}
