import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens the camera and returns the first barcode it reads.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan an item')),
      body: MobileScanner(
        onDetect: (capture) {
          final code = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
          if (code == null || _done) return;
          _done = true;
          Navigator.of(context).pop(code);
        },
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('The camera could not start (${error.errorCode.name}). '
                'Go back and tap the item in the list instead.'),
          ),
        ),
      ),
    );
  }
}
