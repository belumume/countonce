import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:countonce/models.dart';
import 'package:countonce/ui/home_page.dart';
import 'package:countonce/ui/theme.dart';

void main() {
  test('times read as "just now", minutes or hours ago', () {
    final now = DateTime(2026, 11, 11, 12);
    expect(ago(now.subtract(const Duration(seconds: 20)), now), 'just now');
    expect(ago(now.subtract(const Duration(minutes: 4)), now), '4 min ago');
    expect(ago(now.subtract(const Duration(hours: 2)), now), '2 h ago');
    expect(ago(DateTime(2026, 11, 3, 9), now), '3 Nov 2026');
  });

  test('a change always carries its sign', () {
    expect(signed(5), '+5');
    expect(signed(-1), '−1');
  });

  Future<void> openSheet(WidgetTester tester, int qty) => tester.pumpWidget(
    MaterialApp(
      theme: Brand.theme(),
      home: Scaffold(
        body: MoveSheet(
          item: Item(id: 'GLOVE-M', name: 'Work gloves, medium', qty: qty, reorderPoint: 6),
        ),
      ),
    ),
  );

  testWidgets('the sheet shows the stock before and after, and the button says what it will do', (tester) async {
    await openSheet(tester, 12);
    expect(find.text('Take 1 out'), findsOneWidget);
    expect(find.text('11'), findsOneWidget); // 12 -> 11

    await tester.tap(find.byTooltip('One more'));
    await tester.pump();
    expect(find.text('Take 2 out'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);

    await tester.tap(find.text('Put in'));
    await tester.pump();
    expect(find.text('Put 2 in'), findsOneWidget);
    expect(find.text('14'), findsOneWidget);
  });

  testWidgets('a screen reader hears the sheet named and both numbers labelled', (tester) async {
    final handle = tester.ensureSemantics();
    await openSheet(tester, 12);
    expect(find.bySemanticsLabel('Change stock'), findsOneWidget);
    expect(find.bySemanticsLabel('In stock: 12 now, 11 after this change'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('taking out more than the stock shown warns that it will be refused', (tester) async {
    await openSheet(tester, 1);
    expect(find.textContaining('will be refused'), findsNothing);
    await tester.tap(find.byTooltip('One more'));
    await tester.pump();
    expect(find.text('Only 1 in stock, so taking 2 out will be refused.'), findsOneWidget);
  });

  testWidgets('the sheet counts the scans still waiting on the phone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Brand.theme(),
        home: const Scaffold(
          body: MoveSheet(
            item: Item(id: 'TONER-K', name: 'Black toner cartridge', qty: 1, reorderPoint: 2),
            waiting: [-1, -1], // the second will be refused by the API, so stock stays at 0
          ),
        ),
      ),
    );
    expect(find.text('In stock, including 2 not sent yet'), findsOneWidget);
    expect(find.text('Only 0 in stock, so taking 1 out will be refused.'), findsOneWidget);
  });
}
