import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../models/car.dart';
import 'garage_screen.dart';
import 'model_selection_screen.dart';
import 'scan_car_screen.dart';

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
        title: const Text('Select Your Car Brand', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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

                return GridView.builder(
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
