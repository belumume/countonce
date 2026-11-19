import 'package:countonce/ui/scan_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  test('camera errors are explained in plain words, never as a code name', () {
    for (final web in [true, false]) {
      for (final code in MobileScannerErrorCode.values) {
        final text = cameraErrorText(code, web: web);
        expect(text, isNot(contains(code.name)), reason: '${code.name} web=$web');
        expect(text, contains('tap the item in the list'), reason: '${code.name} web=$web');
      }
    }
  });

  test('a browser is told about the browser, the Android app about the phone', () {
    final web = cameraErrorText(MobileScannerErrorCode.permissionDenied, web: true);
    expect(web, contains('browser'));
    expect(web, isNot(contains('phone')));
    expect(cameraErrorText(MobileScannerErrorCode.unsupported, web: true), isNot(contains('phone')));
    expect(cameraErrorText(MobileScannerErrorCode.permissionDenied, web: false), contains("phone's settings"));
  });
}
