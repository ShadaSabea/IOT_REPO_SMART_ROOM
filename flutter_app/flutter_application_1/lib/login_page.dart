import 'package:flutter/material.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in')),
      body: const Center(
        child: Text(
          'Login form with FirebaseAuth will be here',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
