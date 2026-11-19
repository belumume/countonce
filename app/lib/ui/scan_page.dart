import 'package:flutter/foundation.dart' show kIsWeb;
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
            child: Text(cameraErrorText(error.errorCode)),
          ),
        ),
      ),
    );
  }
}

/// What the scan screen says when the camera cannot be used, in words a member of staff understands.
/// In a browser the camera is allowed per site, in the browser; in the Android app, in the phone's settings.
String cameraErrorText(MobileScannerErrorCode code, {bool web = kIsWeb}) => switch (code) {
      MobileScannerErrorCode.permissionDenied => web
          ? 'This site is not allowed to use the camera. To scan, allow the camera for this site in your '
              'browser: tap or click the camera or lock icon next to the address. Or go back and tap the item in the list.'
          : 'CountOnce is not allowed to use the camera. To scan, allow the camera for CountOnce in your '
              "phone's settings. Or go back and tap the item in the list.",
      MobileScannerErrorCode.unsupported => web
          ? 'No camera was found. Go back and tap the item in the list instead.'
          : 'This phone has no camera the app can use. Go back and tap the item in the list instead.',
      _ => 'The camera could not start. Go back and tap the item in the list instead.',
    };
