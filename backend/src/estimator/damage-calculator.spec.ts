import { describe, it, expect } from 'vitest';
import {
  calculateRepairEstimate,
  type DamageAssessmentItem,
} from './damage-calculator.js';

describe('calculateRepairEstimate', () => {
  it('returns zero values when damage list is empty', () => {
    const result = calculateRepairEstimate([]);
    expect(result.subtotal).toBe(0);
    expect(result.total).toBe(0);
    expect(result.laborHoursTotal).toBe(0);
    expect(result.breakdown).toHaveLength(0);
  });

  it('calculates minor scratch with buff action and conservative price band', () => {
    const damages: DamageAssessmentItem[] = [
      {
        damageType: 'SCRATCH',
        severity: 'MINOR',
        affectedPanel: 'FRONT_BUMPER',
        areaPercentage: 2.0,
      },
    ];

    const result = calculateRepairEstimate(damages);
    expect(result.laborHoursTotal).toBeGreaterThan(0);
    expect(result.laborCost).toBeGreaterThan(0);
    expect(result.breakdown[0].action).toBe('BUFF');
    expect(result.partsCost).toBe(0); // Minor scratch doesn't replace part
    expect(result.total).toBeGreaterThan(result.subtotal); // Tax included
    expect(result.priceBandMin).toBeLessThan(result.total);
    expect(result.priceBandMax).toBeGreaterThan(result.total);
  });

  it('correctly triggers replacement part cost for shattered glass or critical damage', () => {
    const damages: DamageAssessmentItem[] = [
      {
        damageType: 'SHATTER',
        severity: 'SEVERE',
        affectedPanel: 'WINDSHIELD',
        areaPercentage: 60.0,
      },
    ];

    const result = calculateRepairEstimate(damages);
    expect(result.breakdown[0].action).toBe('REPLACE');
    expect(result.partsCost).toBe(390.0); // Allowance for windshield
    expect(result.total).toBeGreaterThan(500);
  });

  it('handles multiple multi-panel damages correctly aggregating subtotals and tax', () => {
    const damages: DamageAssessmentItem[] = [
      {
        damageType: 'DENT',
        severity: 'MODERATE',
        affectedPanel: 'HOOD',
        areaPercentage: 12.0,
      },
      {
        damageType: 'SCRATCH',
        severity: 'SEVERE',
        affectedPanel: 'DRIVER_DOOR',
        areaPercentage: 18.0,
      },
      {
        damageType: 'CRACK',
        severity: 'MINOR',
        affectedPanel: 'REAR_BUMPER',
        areaPercentage: 5.0,
      },
    ];

    const result = calculateRepairEstimate(damages);
    expect(result.breakdown).toHaveLength(3);
    const sumLaborCost = result.breakdown.reduce((sum, b) => sum + b.laborCost, 0);
    const sumPaintCost = result.breakdown.reduce((sum, b) => sum + b.paintMaterialCost, 0);
    const sumPartsCost = result.breakdown.reduce((sum, b) => sum + b.partsCost, 0);

    expect(result.laborCost).toBeCloseTo(sumLaborCost, 2);
    expect(result.paintMaterialCost).toBeCloseTo(sumPaintCost, 2);
    expect(result.partsCost).toBeCloseTo(sumPartsCost, 2);
    expect(result.subtotal).toBeCloseTo(sumLaborCost + sumPaintCost + sumPartsCost, 2);
    expect(result.total).toBeCloseTo(result.subtotal + result.tax, 2);
    expect(result.priceBandMin).toBeLessThan(result.total);
    expect(result.priceBandMax).toBeGreaterThan(result.total);
  });
});
