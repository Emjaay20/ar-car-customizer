import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../services/auth_session.dart';
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
      appBar: AppBar(title: const Text('AR Car Customizer')),
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
            ],
          ),
        ),
      ),
    );
  }
}
