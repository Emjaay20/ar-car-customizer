import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../models/car.dart';
import '../services/auth_session.dart';
import 'customization_screen.dart';

class GarageScreen extends StatefulWidget {
  const GarageScreen({super.key});

  @override
  State<GarageScreen> createState() => _GarageScreenState();
}

class _GarageScreenState extends State<GarageScreen> {
  final _shareCode = TextEditingController();

  static const String mineQuery = r'''
    query Mine {
      myConfigurations {
        id
        name
        status
        shareToken
        createdAt
        car { id make model year baseMeshUrl }
        assets { id name type }
      }
    }
  ''';

  static const String shareMutation = r'''
    mutation Share($id: ID!) {
      shareConfiguration(id: $id) {
        id
        shareToken
      }
    }
  ''';

  static const String sharedQuery = r'''
    query Shared($token: String!) {
      sharedConfiguration(token: $token) {
        id
        name
        status
        car { id make model year baseMeshUrl }
        assets { name type }
      }
    }
  ''';

  Future<void> _share(String id) async {
    final client = GraphQLProvider.of(context).value;
    final result = await client.mutate(
      MutationOptions(document: gql(shareMutation), variables: {'id': id}),
    );
    if (!mounted) return;
    final token = result.data?['shareConfiguration']?['shareToken'];
    if (result.hasException || token is! String) {
      _snack('Could not create a share code.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    _snack('Share code copied.');
  }

  Future<void> _openShare() async {
    final token = _shareCode.text.trim();
    if (token.isEmpty) return;
    final client = GraphQLProvider.of(context).value;
    final result = await client.query(
      QueryOptions(document: gql(sharedQuery), variables: {'token': token}),
    );
    if (!mounted) return;
    final shared = result.data?['sharedConfiguration'];
    if (result.hasException || shared is! Map || shared['car'] is! Map) {
      _snack('No garage entry for that code.');
      return;
    }
    final car = Car.fromJson(Map<String, dynamic>.from(shared['car'] as Map));
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CustomizationScreen(car: car)),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _shareCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthSession.isLoggedIn) {
      return const Scaffold(body: Center(child: Text('Log in to see your garage.')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Garage')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _shareCode,
                    decoration: const InputDecoration(
                      labelText: 'Open a share code',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: _openShare, icon: const Icon(Icons.login)),
              ],
            ),
          ),
          Expanded(
            child: Query(
              options: QueryOptions(document: gql(mineQuery)),
              builder: (result, {refetch, fetchMore}) {
                if (result.isLoading && result.data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (result.hasException) {
                  return Center(child: Text('Error: ${result.exception}'));
                }
                final rows = ((result.data?['myConfigurations'] ?? []) as List);
                if (rows.isEmpty) {
                  return const Center(child: Text('No saved cars yet.'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = Map<String, dynamic>.from(rows[index] as Map);
                    final carJson = row['car'];
                    final car = carJson is Map
                        ? Car.fromJson(Map<String, dynamic>.from(carJson))
                        : null;
                    final title = (row['name'] as String?)?.isNotEmpty == true
                        ? row['name'] as String
                        : car == null
                            ? 'Saved car'
                            : '${car.year} ${car.make} ${car.model}';
                    final assets = ((row['assets'] ?? []) as List)
                        .whereType<Map>()
                        .map((asset) => asset['name'])
                        .join(', ');
                    return Card(
                      child: ListTile(
                        title: Text(title),
                        subtitle: Text(assets.isEmpty ? row['status'].toString() : assets),
                        trailing: IconButton(
                          tooltip: 'Copy share code',
                          icon: const Icon(Icons.share),
                          onPressed: () => _share(row['id'] as String),
                        ),
                        onTap: car == null
                            ? null
                            : () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => CustomizationScreen(
                                      car: car,
                                      initialVehicleLabel: title,
                                    ),
                                  ),
                                );
                              },
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
