class DamageRecordItem {
  final String? id;
  final String damageType;
  final String severity;
  final double confidence;
  final String affectedPanel;
  final double areaPercentage;
  final String boundingBoxJson;
  final String? spatialAnchorJson;
  final String recommendedAction;
  final double estimatedLaborHours;

  const DamageRecordItem({
    this.id,
    required this.damageType,
    required this.severity,
    required this.confidence,
    required this.affectedPanel,
    required this.areaPercentage,
    required this.boundingBoxJson,
    this.spatialAnchorJson,
    required this.recommendedAction,
    required this.estimatedLaborHours,
  });

  factory DamageRecordItem.fromJson(Map<String, dynamic> json) {
    return DamageRecordItem(
      id: json['id'] as String?,
      damageType: json['damageType'] as String? ?? 'SCRATCH',
      severity: json['severity'] as String? ?? 'MINOR',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.9,
      affectedPanel: json['affectedPanel'] as String? ?? 'FRONT_BUMPER',
      areaPercentage: (json['areaPercentage'] as num?)?.toDouble() ?? 5.0,
      boundingBoxJson: json['boundingBoxJson'] as String? ?? '{}',
      spatialAnchorJson: json['spatialAnchorJson'] as String?,
      recommendedAction: json['recommendedAction'] as String? ?? 'REPAIR',
      estimatedLaborHours: (json['estimatedLaborHours'] as num?)?.toDouble() ?? 1.5,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'damageType': damageType,
      'severity': severity,
      'confidence': confidence,
      'affectedPanel': affectedPanel,
      'areaPercentage': areaPercentage,
      'boundingBoxJson': boundingBoxJson,
      if (spatialAnchorJson != null) 'spatialAnchorJson': spatialAnchorJson,
      'recommendedAction': recommendedAction,
      'estimatedLaborHours': estimatedLaborHours,
    };
  }
}

class CostEstimateData {
  final String id;
  final double laborCost;
  final double paintMaterialCost;
  final double partsCost;
  final double subtotal;
  final double tax;
  final double total;
  final String currency;
  final double priceBandMin;
  final double priceBandMax;

  const CostEstimateData({
    required this.id,
    required this.laborCost,
    required this.paintMaterialCost,
    required this.partsCost,
    required this.subtotal,
    required this.tax,
    required this.total,
    required this.currency,
    required this.priceBandMin,
    required this.priceBandMax,
  });

  factory CostEstimateData.fromJson(Map<String, dynamic> json) {
    return CostEstimateData(
      id: json['id'] as String? ?? '',
      laborCost: (json['laborCost'] as num?)?.toDouble() ?? 0.0,
      paintMaterialCost: (json['paintMaterialCost'] as num?)?.toDouble() ?? 0.0,
      partsCost: (json['partsCost'] as num?)?.toDouble() ?? 0.0,
      subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0.0,
      tax: (json['tax'] as num?)?.toDouble() ?? 0.0,
      total: (json['total'] as num?)?.toDouble() ?? 0.0,
      currency: json['currency'] as String? ?? 'USD',
      priceBandMin: (json['priceBandMin'] as num?)?.toDouble() ?? 0.0,
      priceBandMax: (json['priceBandMax'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class JobCardData {
  final String id;
  final String jobNumber;
  final String status;
  final String priority;
  final String? technicianName;
  final String? customerNotes;
  final String? internalNotes;
  final String createdAt;

  const JobCardData({
    required this.id,
    required this.jobNumber,
    required this.status,
    required this.priority,
    this.technicianName,
    this.customerNotes,
    this.internalNotes,
    required this.createdAt,
  });

  factory JobCardData.fromJson(Map<String, dynamic> json) {
    return JobCardData(
      id: json['id'] as String? ?? '',
      jobNumber: json['jobNumber'] as String? ?? '',
      status: json['status'] as String? ?? 'DRAFT',
      priority: json['priority'] as String? ?? 'NORMAL',
      technicianName: json['technicianName'] as String?,
      customerNotes: json['customerNotes'] as String?,
      internalNotes: json['internalNotes'] as String?,
      createdAt: json['createdAt'] as String? ?? '',
    );
  }
}
