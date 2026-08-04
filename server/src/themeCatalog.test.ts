import assert from 'node:assert/strict';
import test from 'node:test';
import {
  isValidThemeId,
  ThemeCatalogEntry,
  themeOfferMatchesExpectation
} from './themeCatalog.js';

const swordFrost: ThemeCatalogEntry = {
  themeId: 'sword-frost',
  displayName: '剑影青霜',
  pricePoints: 60,
  validDays: 365
};

test('theme ids accept stable kebab-case identifiers', () => {
  assert.equal(isValidThemeId('sword-frost'), true);
  assert.equal(isValidThemeId('theme-2'), true);
});

test('theme ids reject unsafe or ambiguous identifiers', () => {
  assert.equal(isValidThemeId(''), false);
  assert.equal(isValidThemeId('Sword-Frost'), false);
  assert.equal(isValidThemeId('../sword-frost'), false);
  assert.equal(isValidThemeId('sword--frost'), false);
  assert.equal(isValidThemeId(`${'a'.repeat(64)}-b`), false);
});

test('new clients must confirm the exact database offer', () => {
  assert.equal(themeOfferMatchesExpectation(swordFrost, 60, 365), true);
  assert.equal(themeOfferMatchesExpectation(swordFrost, 59, 365), false);
  assert.equal(themeOfferMatchesExpectation(swordFrost, 60, undefined), false);
});

test('legacy clients can only redeem the legacy 60-point 365-day offer', () => {
  assert.equal(themeOfferMatchesExpectation(swordFrost, undefined, undefined), true);
  assert.equal(themeOfferMatchesExpectation(
    { ...swordFrost, pricePoints: 100 }, undefined, undefined), false);
});
