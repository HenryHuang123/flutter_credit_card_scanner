import 'package:flutter/material.dart';
import 'package:flutter_credit_card_scanner_example/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyMaterialApp());
}

class MyMaterialApp extends StatelessWidget {
  const MyMaterialApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: MyAppCreditCardScanner()),
    );
  }
}
