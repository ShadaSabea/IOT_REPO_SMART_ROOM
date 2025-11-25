import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  bool _hasScanned = false; // prevents double scanning

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Scan QR Code"),
        centerTitle: true,
      ),
      body: MobileScanner(
        onDetect: (BarcodeCapture capture) {
          if (_hasScanned) return;
          _hasScanned = true;

          final List<Barcode> barcodes = capture.barcodes;

          if (barcodes.isNotEmpty) {
            final value = barcodes.first.rawValue ?? "";

            // ✅ RETURN THE SCANNED TEXT TO THE PREVIOUS PAGE
            Navigator.pop(context, value);
          }
        },
     ),
);
}
}