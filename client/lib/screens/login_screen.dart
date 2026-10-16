import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../services/auth_session.dart';
import '../services/graphql_service.dart';
import 'brand_selection_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController(text: 'demo@arcar.com');
  final _passwordController = TextEditingController(text: 'demo-password');
  final _nameController = TextEditingController();
  bool _isLoading = false;
  bool _registering = false;
  String? _error;

  static const String loginMutation = r'''
    mutation Login($input: LoginInput!) {
      login(input: $input) {
        token
        user { id email fullName }
      }
    }
  ''';

  static const String registerMutation = r'''
    mutation Register($input: RegisterInput!) {
      register(input: $input) {
        token
        user { id email fullName }
      }
    }
  ''';

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    if (_registering && _nameController.text.trim().length < 2) {
      setState(() {
        _isLoading = false;
        _error = 'Enter your name.';
      });
      return;
    }
    if (_registering && _passwordController.text.length < 8) {
      setState(() {
        _isLoading = false;
        _error = 'Password must be at least 8 characters.';
      });
      return;
    }

    final client = GraphQLProvider.of(context).value;
    final result = await client.mutate(
      MutationOptions(
        document: gql(_registering ? registerMutation : loginMutation),
        variables: {
          'input': {
            'email': _emailController.text.trim(),
            'password': _passwordController.text,
            if (_registering) 'fullName': _nameController.text.trim(),
          },
        },
      ),
    );

    if (!mounted) return;

    final payload = result.data?[_registering ? 'register' : 'login'];
    if (result.hasException || payload == null) {
      setState(() {
        _isLoading = false;
        _error = result.exception?.graphqlErrors.isNotEmpty == true
            ? result.exception!.graphqlErrors.first.message
            : 'Login failed. Is the backend running, and has it been seeded?';
      });
      return;
    }

    AuthSession.setFromLogin(Map<String, dynamic>.from(payload as Map));
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const BrandSelectionScreen()),
    );
  }

  void _showServerUrlDialog() {
    final controller = TextEditingController(text: GraphQLService.apiUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backend Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'GraphQL API URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.cloud, size: 16),
              label: const Text('Use Cloud (AetherHost)'),
              onPressed: () {
                controller.text = 'https://ar-car-backend.aetherhost.com.ng/graphql';
              },
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              icon: const Icon(Icons.wifi, size: 16),
              label: const Text('Use Local LAN (192.168.100.66)'),
              onPressed: () {
                controller.text = 'http://192.168.100.66:3000/graphql';
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              GraphQLService.setApiUrl(controller.text);
              Navigator.pop(ctx);
              setState(() {
                _error = null;
              });
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Car Customizer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Server Settings',
            onPressed: _showServerUrlDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            children: [
              const Icon(Icons.directions_car, size: 80),
              const SizedBox(height: 32),
              if (_registering) ...[
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : Text(_registering ? 'Create account' : 'Log in'),
              ),
              TextButton(
                onPressed: _isLoading
                    ? null
                    : () => setState(() {
                          _registering = !_registering;
                          _error = null;
                        }),
                child: Text(_registering ? 'I already have an account' : 'Create an account'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Seeded demo account: demo@arcar.com / demo-password',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: _showServerUrlDialog,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_done_outlined, size: 16, color: Color(0xFF00E5FF)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          GraphQLService.apiUrl,
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.edit, size: 14, color: Colors.white54),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
