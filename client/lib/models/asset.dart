class Asset {
  final String id;
  final String name;
  final String type;
  final double price;
  final String materialBundleUrl;
  final String anchor;

  Asset({
    required this.id,
    required this.name,
    required this.type,
    required this.price,
    required this.materialBundleUrl,
    this.anchor = 'body',
  });

  factory Asset.fromJson(Map<String, dynamic> json) {
    return Asset(
      id: json['id'],
      name: json['name'],
      type: json['type'],
      price: (json['price'] as num).toDouble(),
      materialBundleUrl: json['materialBundleUrl'],
      anchor: json['anchor'] as String? ?? 'body',
    );
  }
}