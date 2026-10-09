import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'services/graphql_service.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initHiveForFlutter();
  debugPrint('API_URL=${GraphQLService.apiUrl}');

  final client = GraphQLService.getClientNotifier();

  runApp(
    GraphQLProvider(
      client: client,
      child: const ARCarCustomizerApp(),
    ),
  );
}

class ARCarCustomizerApp extends StatelessWidget {
  const ARCarCustomizerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Car Customizer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E88E5)),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}