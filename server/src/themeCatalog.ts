import { PoolClient } from 'pg';

interface Queryable {
  query: PoolClient['query'];
}

interface ThemeCatalogRow {
  theme_id: string;
  display_name: string;
  price_points: string;
  valid_days: number;
}

export interface ThemeCatalogEntry {
  themeId: string;
  displayName: string;
  pricePoints: number;
  validDays: number;
}

const LEGACY_THEME_PRICE_POINTS = 60;
const LEGACY_THEME_VALID_DAYS = 365;

export function isValidThemeId(themeId: string): boolean {
  return themeId.length <= 64 && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(themeId);
}

export function themeOfferMatchesExpectation(
  theme: ThemeCatalogEntry,
  expectedPricePoints: number | undefined,
  expectedValidDays: number | undefined
): boolean {
  if (expectedPricePoints === undefined && expectedValidDays === undefined) {
    return theme.pricePoints === LEGACY_THEME_PRICE_POINTS &&
      theme.validDays === LEGACY_THEME_VALID_DAYS;
  }
  return expectedPricePoints === theme.pricePoints && expectedValidDays === theme.validDays;
}

export async function listPublishedThemes(db: Queryable): Promise<ThemeCatalogEntry[]> {
  const result = await db.query<ThemeCatalogRow>(
    `SELECT theme_id, display_name, price_points, valid_days
     FROM theme_catalog
     WHERE enabled = TRUE
     ORDER BY theme_id`
  );
  return result.rows.map(toThemeCatalogEntry);
}

export async function findRedeemableTheme(
  db: Queryable,
  themeId: string
): Promise<ThemeCatalogEntry | null> {
  if (!isValidThemeId(themeId)) return null;
  const result = await db.query<ThemeCatalogRow>(
    `SELECT theme_id, display_name, price_points, valid_days
     FROM theme_catalog
     WHERE theme_id = $1 AND enabled = TRUE`,
    [themeId]
  );
  const row = result.rows[0];
  return row ? toThemeCatalogEntry(row) : null;
}

function toThemeCatalogEntry(row: ThemeCatalogRow): ThemeCatalogEntry {
  return {
    themeId: row.theme_id,
    displayName: row.display_name,
    pricePoints: Number(row.price_points),
    validDays: row.valid_days
  };
}
