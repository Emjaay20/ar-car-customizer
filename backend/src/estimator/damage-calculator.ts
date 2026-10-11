export type DamageType =
  | 'SCRATCH'
  | 'DENT'
  | 'CRACK'
  | 'TEAR'
  | 'SHATTER'
  | 'RUST'
  | 'PAINT_CHIP';

export type SeverityLevel = 'MINOR' | 'MODERATE' | 'SEVERE' | 'CRITICAL';

export type RepairAction =
  | 'REPAIR'
  | 'REPLACE'
  | 'REPAINT'
  | 'BUFF'
  | 'INSPECT_FURTHER';

export interface DamageAssessmentItem {
  id?: string;
  damageType: DamageType;
  severity: SeverityLevel;
  affectedPanel: string;
  areaPercentage: number;
  confidence?: number;
  recommendedAction?: RepairAction;
  estimatedLaborHours?: number;
}

export interface PanelCostBreakdown {
  panel: string;
  damageType: DamageType;
  severity: SeverityLevel;
  laborHours: number;
  laborCost: number;
  paintMaterialCost: number;
  partsCost: number;
  action: RepairAction;
  panelTotal: number;
}

export interface EstimateResult {
  laborHoursTotal: number;
  laborCost: number;
  paintMaterialCost: number;
  partsCost: number;
  subtotal: number;
  tax: number;
  total: number;
  priceBandMin: number;
  priceBandMax: number;
  currency: string;
  breakdown: PanelCostBreakdown[];
}

export interface EstimatorConfig {
  hourlyLaborRate?: number;
  taxRate?: number;
  basePaintMaterialRate?: number;
}

const DEFAULT_HOURLY_LABOR_RATE = 95.0; // Standard USD shop labor rate
const DEFAULT_TAX_RATE = 0.0825; // 8.25% standard sales/repair tax
const DEFAULT_BASE_PAINT_RATE = 45.0; // Base paint/prep consumables per affected panel

// Complexity multiplier by panel location
const PANEL_COMPLEXITY_MULTIPLIERS: Record<string, number> = {
  HOOD: 1.15,
  ROOF: 1.4,
  FRONT_BUMPER: 1.0,
  REAR_BUMPER: 1.0,
  DRIVER_DOOR: 1.2,
  PASSENGER_DOOR: 1.2,
  QUARTER_PANEL: 1.35,
  FENDER: 1.05,
  TRUNK: 1.1,
  WINDSHIELD: 1.25,
  HEADLIGHT: 0.9,
  TAILLIGHT: 0.9,
};

// Base hours required by damage type and severity
const BASE_LABOR_HOURS: Record<DamageType, Record<SeverityLevel, number>> = {
  SCRATCH: { MINOR: 0.8, MODERATE: 1.5, SEVERE: 2.8, CRITICAL: 4.5 },
  PAINT_CHIP: { MINOR: 0.5, MODERATE: 1.2, SEVERE: 2.2, CRITICAL: 3.8 },
  DENT: { MINOR: 1.2, MODERATE: 2.5, SEVERE: 4.2, CRITICAL: 6.5 },
  CRACK: { MINOR: 1.5, MODERATE: 3.0, SEVERE: 5.0, CRITICAL: 7.5 },
  TEAR: { MINOR: 2.0, MODERATE: 3.8, SEVERE: 6.0, CRITICAL: 8.5 },
  RUST: { MINOR: 1.8, MODERATE: 3.5, SEVERE: 6.5, CRITICAL: 9.5 },
  SHATTER: { MINOR: 2.5, MODERATE: 4.0, SEVERE: 6.0, CRITICAL: 8.0 },
};

// Estimated OEM replacement part allowance when replacement is indicated
const PANEL_REPLACEMENT_ALLOWANCE: Record<string, number> = {
  HOOD: 450.0,
  FRONT_BUMPER: 320.0,
  REAR_BUMPER: 310.0,
  DRIVER_DOOR: 520.0,
  PASSENGER_DOOR: 520.0,
  FENDER: 240.0,
  QUARTER_PANEL: 680.0,
  ROOF: 850.0,
  TRUNK: 380.0,
  WINDSHIELD: 390.0,
  HEADLIGHT: 280.0,
  TAILLIGHT: 220.0,
};

function roundCents(val: number): number {
  return Math.round((val + Number.EPSILON) * 100) / 100;
}

export function calculateRepairEstimate(
  damages: DamageAssessmentItem[],
  config: EstimatorConfig = {},
): EstimateResult {
  const laborRate = config.hourlyLaborRate ?? DEFAULT_HOURLY_LABOR_RATE;
  const taxRate = config.taxRate ?? DEFAULT_TAX_RATE;
  const basePaintRate = config.basePaintMaterialRate ?? DEFAULT_BASE_PAINT_RATE;

  if (!damages || damages.length === 0) {
    return {
      laborHoursTotal: 0,
      laborCost: 0,
      paintMaterialCost: 0,
      partsCost: 0,
      subtotal: 0,
      tax: 0,
      total: 0,
      priceBandMin: 0,
      priceBandMax: 0,
      currency: 'USD',
      breakdown: [],
    };
  }

  let totalLaborHours = 0;
  let totalLaborCost = 0;
  let totalPaintCost = 0;
  let totalPartsCost = 0;
  const breakdown: PanelCostBreakdown[] = [];

  for (const item of damages) {
    const normPanel = (item.affectedPanel || 'FRONT_BUMPER').toUpperCase().trim();
    const panelMultiplier = PANEL_COMPLEXITY_MULTIPLIERS[normPanel] ?? 1.1;
    const baseHours =
      BASE_LABOR_HOURS[item.damageType]?.[item.severity] ??
      item.estimatedLaborHours ??
      1.5;

    // Area scaling: small blemishes need baseline work; larger areas (>15%) require extended blending/bodywork
    const areaFactor = item.areaPercentage > 15 ? 1 + (item.areaPercentage - 15) * 0.02 : 1.0;
    const laborHours = roundCents(baseHours * panelMultiplier * areaFactor);
    const laborCost = roundCents(laborHours * laborRate);

    // Determine paint and material cost
    let paintCost = 0;
    if (['SCRATCH', 'PAINT_CHIP', 'RUST', 'DENT'].includes(item.damageType)) {
      const paintAreaMultiplier = 1 + Math.max(0, item.areaPercentage) * 0.05;
      paintCost = roundCents(basePaintRate * panelMultiplier * paintAreaMultiplier);
    }

    // Determine repair action and replacement part cost
    let action: RepairAction = item.recommendedAction ?? 'REPAIR';
    let partsCost = 0;

    if (
      item.severity === 'CRITICAL' ||
      item.damageType === 'SHATTER' ||
      item.damageType === 'TEAR' ||
      action === 'REPLACE'
    ) {
      action = 'REPLACE';
      partsCost = roundCents(PANEL_REPLACEMENT_ALLOWANCE[normPanel] ?? 300.0);
    } else if (item.damageType === 'SCRATCH' && item.severity === 'MINOR') {
      action = 'BUFF';
      paintCost = roundCents(paintCost * 0.4);
    } else if (item.damageType === 'PAINT_CHIP' || item.damageType === 'SCRATCH') {
      action = 'REPAINT';
    }

    const panelTotal = roundCents(laborCost + paintCost + partsCost);

    totalLaborHours += laborHours;
    totalLaborCost += laborCost;
    totalPaintCost += paintCost;
    totalPartsCost += partsCost;

    breakdown.push({
      panel: normPanel,
      damageType: item.damageType,
      severity: item.severity,
      laborHours,
      laborCost,
      paintMaterialCost: paintCost,
      partsCost,
      action,
      panelTotal,
    });
  }

  const subtotal = roundCents(totalLaborCost + totalPaintCost + totalPartsCost);
  const tax = roundCents(subtotal * taxRate);
  const total = roundCents(subtotal + tax);

  // Price bands: -12% for best-case/discount, +18% contingency for internal structural discoveries
  const priceBandMin = roundCents(total * 0.88);
  const priceBandMax = roundCents(total * 1.18);

  return {
    laborHoursTotal: roundCents(totalLaborHours),
    laborCost: roundCents(totalLaborCost),
    paintMaterialCost: roundCents(totalPaintCost),
    partsCost: roundCents(totalPartsCost),
    subtotal,
    tax,
    total,
    priceBandMin,
    priceBandMax,
    currency: 'USD',
    breakdown,
  };
}
