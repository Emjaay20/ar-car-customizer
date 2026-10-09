import 'package:flutter/material.dart';
import '../models/car.dart';
import 'customization_screen.dart';

class ModelSelectionScreen extends StatelessWidget {
  final String brand;
  final List<Car> cars;

  const ModelSelectionScreen({super.key, required this.brand, required this.cars});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('$brand Models')),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: cars.length,
        itemBuilder: (context, index) {
          final car = cars[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              title: Text(car.model, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              subtitle: Text('Year: ${car.year}'),
              trailing: const Icon(Icons.arrow_forward_ios),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => CustomizationScreen(car: car)),
                );
              },
            ),
          );
        },
      ),
    );
  }
}