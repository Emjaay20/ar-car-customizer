export const MIN_IDENTIFICATION_CONFIDENCE = 0.45;
export const MAX_CATALOG_YEAR_DELTA = 1;

export interface VehicleGuess {
  make: string;
  model: string;
  year: number;
  confidence: number;
}

export interface CatalogCar {
  id: string;
  make: string;
  model: string;
  year: number;
  baseMeshUrl: string;
}

export interface CatalogMatch {
  car: CatalogCar;
  yearExact: boolean;
}

export function parseVehicleJson(text: string): VehicleGuess | null {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;

  let data: unknown;
  try {
    data = JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
  if (!data || typeof data !== 'object') return null;

  const row = data as Record<string, unknown>;
  const make = stringField(row.make);
  const model = stringField(row.model);
  const year = numberField(row.year);
  let confidence = numberField(row.confidence);
  if (!make || !model || year == null || confidence == null) return null;
  if (year < 1950 || year > 2100) return null;
  if (confidence > 1 && confidence <= 100) confidence /= 100;
  if (confidence < 0 || confidence > 1) return null;

  return { make, model, year: Math.round(year), confidence };
}

export function matchCatalog(
  guess: VehicleGuess,
  cars: CatalogCar[],
  maxYearDelta = MAX_CATALOG_YEAR_DELTA,
): CatalogMatch | null {
  const wantedMake = normalize(guess.make);
  const wantedModel = normalize(guess.model);
  const ranked: Array<{ car: CatalogCar; modelScore: number; yearDelta: number }> = [];

  for (const car of cars) {
    if (normalize(car.make) !== wantedMake) continue;
    const modelScore = scoreModel(normalize(car.model), wantedModel);
    if (modelScore == null) continue;
    ranked.push({
      car,
      modelScore,
      yearDelta: Math.abs(car.year - guess.year),
    });
  }

  ranked.sort(
    (a, b) =>
      a.modelScore - b.modelScore ||
      a.yearDelta - b.yearDelta ||
      b.car.year - a.car.year,
  );
  const best = ranked[0];
  if (!best || best.yearDelta > maxYearDelta) return null;
  return { car: best.car, yearExact: best.yearDelta === 0 };
}

function scoreModel(catalog: string, guess: string): number | null {
  if (catalog === guess) return 0;
  if (guess.startsWith(`${catalog} `) || catalog.startsWith(`${guess} `)) return 1;
  return null;
}

function normalize(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, ' ');
}

function stringField(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function numberField(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}
