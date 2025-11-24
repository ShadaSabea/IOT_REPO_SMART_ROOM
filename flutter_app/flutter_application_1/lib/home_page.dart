import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Smart Room - Home"),
      ),
      body: const Center(
        child: Text(
          "Welcome to the Smart Room App!",
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}
