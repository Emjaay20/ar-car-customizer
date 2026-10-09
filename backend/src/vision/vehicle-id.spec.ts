import { describe, expect, it } from 'vitest';
import { matchCatalog, parseVehicleJson, type CatalogCar } from './vehicle-id.js';

const civic: CatalogCar = {
  id: 'civic',
  make: 'Honda',
  model: 'Civic',
  year: 2018,
  baseMeshUrl: '/models/cesium-milk-truck.glb',
};

const camry: CatalogCar = {
  id: 'camry',
  make: 'Toyota',
  model: 'Camry',
  year: 2018,
  baseMeshUrl: '/models/cesium-milk-truck.glb',
};

describe('parseVehicleJson', () => {
  it('reads a fenced JSON reply and a percent confidence', () => {
    const guess = parseVehicleJson('```json\n{"make":"Honda","model":"Civic","year":"2018","confidence":82}\n```');
    expect(guess).toEqual({
      make: 'Honda',
      model: 'Civic',
      year: 2018,
      confidence: 0.82,
    });
  });

  it('rejects an empty identification', () => {
    expect(parseVehicleJson('{"make":"","model":"","year":0,"confidence":0}')).toBeNull();
  });
});

describe('matchCatalog', () => {
  it('matches make, model, and year without borrowing another car', () => {
    const match = matchCatalog(
      { make: 'honda', model: 'Civic Si', year: 2018, confidence: 0.9 },
      [camry, civic],
    );
    expect(match?.car.id).toBe('civic');
    expect(match?.yearExact).toBe(true);
  });

  it('accepts a one-year catalog neighbor and rejects a larger gap', () => {
    expect(
      matchCatalog(
        { make: 'Honda', model: 'Civic', year: 2019, confidence: 0.8 },
        [civic],
      )?.yearExact,
    ).toBe(false);

    expect(
      matchCatalog(
        { make: 'Honda', model: 'Civic', year: 2022, confidence: 0.8 },
        [civic],
      ),
    ).toBeNull();
  });
});
