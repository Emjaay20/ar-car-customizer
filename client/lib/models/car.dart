class Car {
  final String id;
  final String make;
  final String model;
  final int year;
  final String baseMeshUrl;

  Car({
    required this.id,
    required this.make,
    required this.model,
    required this.year,
    required this.baseMeshUrl,
  });

  factory Car.fromJson(Map<String, dynamic> json) {
    return Car(
      id: json['id'],
      make: json['make'],
      model: json['model'],
      year: json['year'],
      baseMeshUrl: json['baseMeshUrl'],
    );
  }
}