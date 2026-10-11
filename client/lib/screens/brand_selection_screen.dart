import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../models/car.dart';
import 'customization_screen.dart';
import 'garage_screen.dart';
import 'model_selection_screen.dart';
import 'scan_car_screen.dart';
import 'workshop_screen.dart';

class BrandSelectionScreen extends StatelessWidget {
  const BrandSelectionScreen({super.key});

  static const String getCarsQuery = r'''
    query GetCars {
      cars {
        id
        make
        model
        year
        baseMeshUrl
      }
    }
  ''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AutoCraft AR & AI', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const WorkshopScreen()),
                  );
                },
                icon: const Icon(Icons.build_circle_outlined),
                label: const Text('Auto Workshop & AI Inspection'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ScanCarScreen()),
                      );
                    },
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Scan a car'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const GarageScreen()),
                      );
                    },
                    icon: const Icon(Icons.garage_outlined),
                    label: const Text('Garage'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Query(
              options: QueryOptions(document: gql(getCarsQuery)),
              builder: (QueryResult result, {VoidCallback? refetch, FetchMore? fetchMore}) {
                if (result.hasException) {
                  return Center(child: Text('Error: ${result.exception}'));
                }
                if (result.isLoading && result.data == null) {
                  return const Center(child: CircularProgressIndicator());
                }

                final List carsJson = result.data?['cars'] ?? [];
                final List<Car> cars = carsJson.map((json) => Car.fromJson(json)).toList();
                final Map<String, List<Car>> carsByBrand = {};
                for (var car in cars) {
                  carsByBrand.putIfAbsent(car.make, () => []).add(car);
                }

                if (carsByBrand.isEmpty) {
                  return const Center(child: Text('No cars available.'));
                }

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CustomizationScreen(
                                car: cars.first,
                                isUniversalMode: true,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF1A2536), Color(0xFF0F1722)],
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.auto_fix_high, color: Color(0xFF00E5FF), size: 32),
                              SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Universal Live AR Paint Studio (Any Car)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                        color: Colors.white,
                                      ),
                                    ),
                                    SizedBox(height: 3),
                                    Text(
                                      'Mask any vehicle (Corolla, Camry, Matrix, SUV, Sedan) in 1:1 live AR & save to your Garage',
                                      style: TextStyle(fontSize: 12, color: Colors.white70),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.arrow_forward_ios, color: Color(0xFF00E5FF), size: 16),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                        itemCount: carsByBrand.keys.length,
                        itemBuilder: (context, index) {
                          final brand = carsByBrand.keys.elementAt(index);
                          final brandCars = carsByBrand[brand]!;
                          return InkWell(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ModelSelectionScreen(brand: brand, cars: brandCars),
                                ),
                              );
                            },
                            child: Card(
                              elevation: 3,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.directions_car_filled, size: 64, color: Colors.black87),
                                  const SizedBox(height: 16),
                                  Text(brand, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                                  Text('${brandCars.length} models', style: const TextStyle(color: Colors.grey)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
