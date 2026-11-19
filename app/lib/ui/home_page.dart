import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import 'scan_page.dart';
import 'sign_in.dart';
import 'theme.dart';

class HomePage extends StatelessWidget {
  final StaffLogic logic;
  const HomePage({super.key, required this.logic});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: logic,
      builder: (context, _) {
        final now = DateTime.now();
        final waiting = logic.waiting;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: const Row(children: [Mark(), SizedBox(width: 12), Text('Stock')]),
            actions: [
              StatusPill(logic: logic),
              const SizedBox(width: 8),
              // A visitor has no name or key to change; "Leave practice" is in the banner instead.
              if (!logic.visitorMode) ...[
                _NameChip(name: logic.staff, onTap: () => _signIn(context)),
                const SizedBox(width: 4),
              ] else
                const SizedBox(width: 8),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: BigButton(label: 'Scan a label', icon: Icons.qr_code_scanner, onPressed: () => _scan(context)),
            ),
          ),
          body: Column(
            children: [
              if (logic.visitorMode) VisitorBanner(logic: logic),
              Expanded(
                child: RefreshIndicator(
                  color: Brand.ink,
                  onRefresh: logic.tick,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      ?_banner(context),
                      // Inside the Try it page the same steps are printed beside the phone, so the guide is not shown twice.
                      if (logic.showGuide && !logic.embedded) VisitorGuide(onDone: logic.dismissGuide),
                      const _Section('Items', trailing: 'In stock'),
                      for (final i in logic.items)
                        _ItemRow(
                          item: i,
                          waiting: [
                            for (final m in waiting)
                              if (m.itemId == i.id) m.delta,
                          ],
                          onTap: () => _record(context, i),
                        ),
                      if (logic.items.isEmpty)
                        const _Note(
                          'Loading the stock list. It needs the network the first time; after that the phone keeps a copy.',
                        ),
                      if (waiting.isNotEmpty) ...[
                        _Section('Waiting to send (${waiting.length})'),
                        for (final m in waiting)
                          _LogRow(
                            delta: m.delta,
                            name: _name(m.itemId),
                            detail: 'Scanned by ${logic.visitorMode ? 'you' : m.staff}, not sent yet',
                            when: ago(m.scannedAt, now),
                            icon: Icons.schedule,
                            iconColor: Brand.muted,
                          ),
                      ],
                      if (logic.recent.isNotEmpty) ...[
                        const _Section('Sent'),
                        for (final o in logic.recent)
                          _LogRow(
                            delta: o.movement.delta,
                            name: _name(o.movement.itemId),
                            detail: _explain(o),
                            when: ago(o.movement.scannedAt, now),
                            icon: o.result == 'applied' ? Icons.check_circle : Icons.block,
                            iconColor: o.result == 'applied' ? Brand.ok : Brand.bad,
                            struck: o.result != 'applied',
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The state of the connection, said in words across the top of the screen whenever it is not normal.
  Widget? _banner(BuildContext context) {
    final n = logic.waiting.length;
    final scans = n == 1 ? '1 scan' : '$n scans';
    // A visitor never sees the staff key or the staff sign-in.
    if (logic.needsKey && !logic.visitorMode) {
      return _Banner(
        icon: Icons.key_off_outlined,
        title: 'Staff key not accepted',
        body: n == 0
            ? 'Enter the right key to change stock.'
            : '$scans saved on this phone. Enter the right key to send them.',
        action: TextButton(
          onPressed: () => _signIn(context, problem: 'The stock API did not accept this staff key.'),
          style: TextButton.styleFrom(foregroundColor: Brand.amber),
          child: const Text('Enter key', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      );
    }
    if (logic.serverError) {
      return _Banner(
        icon: Icons.error_outline,
        title: n == 0 ? 'The server has a problem' : 'The server has a problem. $scans waiting',
        body: 'Scans are saved on this phone and sent again every few seconds.',
      );
    }
    if (logic.online == false) {
      return _Banner(
        icon: Icons.cloud_off,
        title: n == 0 ? 'No signal' : '$scans saved on this phone',
        body: switch (n) {
          0 => 'The stock shown is from the last time the phone had signal. Scans are saved and sent later.',
          1 => 'It will be sent when the signal returns.',
          _ => 'They will be sent when the signal returns.',
        },
      );
    }
    return null;
  }

  String _name(String id) => logic.items.where((i) => i.id == id).map((i) => i.name).firstOrNull ?? id;

  static String _explain(Outcome o) {
    switch (o.result) {
      case 'applied':
        return '${o.repeated ? 'Sent twice, counted once' : 'Recorded'}. Stock now ${o.qty}';
      case 'refused':
        return 'Refused: ${o.reason ?? 'not enough stock'}';
      default:
        return 'Not accepted: ${o.reason ?? 'bad request'}';
    }
  }

  Future<void> _signIn(BuildContext context, {String? problem}) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    barrierLabel: 'Close',
    builder: (sheet) => SheetName(
      'Change your name or staff key',
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(sheet).viewInsets.bottom),
        child: SignInForm(logic: logic, problem: problem, onDone: () => Navigator.of(sheet).pop()),
      ),
    ),
  );

  Future<void> _scan(BuildContext context) async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !context.mounted) return;
    final item = logic.itemFor(code);
    if (item == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No item has the code "$code".')));
      return;
    }
    await _record(context, item);
  }

  Future<void> _record(BuildContext context, Item item) async {
    final delta = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      barrierLabel: 'Close',
      builder: (_) => MoveSheet(
        item: item,
        waiting: [
          for (final m in logic.waiting)
            if (m.itemId == item.id) m.delta,
        ],
      ),
    );
    if (delta != null) await logic.record(item, delta);
  }
}

/// The stock as it will be once the scans waiting on the phone are sent, applied the way the API will:
/// in order, and a take-out that would go below zero is refused.
int projected(int qty, List<int> waiting) => waiting.fold(qty, (s, d) => s + d < 0 ? s : s + d);

/// Take out or put in, and how many. Shows what the stock will be before the button is pressed.
class MoveSheet extends StatefulWidget {
  final Item item;
  final List<int> waiting; // the changes of this item's scans still waiting on the phone, oldest first
  const MoveSheet({super.key, required this.item, this.waiting = const []});

  @override
  State<MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends State<MoveSheet> {
  bool out = true;
  int count = 1;

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final now = projected(i.qty, widget.waiting);
    final after = out ? now - count : now + count;
    final refused = after < 0;
    final stockLabel = widget.waiting.isEmpty ? 'In stock' : 'In stock, including ${widget.waiting.length} not sent yet';
    return SheetName(
      'Change stock',
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(i.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            Row(children: [IdTag(i.id)]),
            const SizedBox(height: 20),
            _Toggle(out: out, onChanged: (v) => setState(() => out = v)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Step(icon: Icons.remove, label: 'One fewer', onTap: count > 1 ? () => setState(() => count--) : null),
                SizedBox(
                  width: 96,
                  child: Text(
                    '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: Brand.mono, fontWeight: FontWeight.w600, fontSize: 44),
                  ),
                ),
                _Step(icon: Icons.add, label: 'One more', onTap: count < 1000 ? () => setState(() => count++) : null),
              ],
            ),
            const SizedBox(height: 20),
            // Both numbers carry a word, so it is clear which is the stock now and which is after this change.
            Semantics(
              label: refused ? '$stockLabel: $now' : '$stockLabel: $now now, $after after this change',
              excludeSemantics: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: Brand.paper, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        stockLabel,
                        style: const TextStyle(fontSize: 16, color: Brand.muted, fontWeight: FontWeight.w600),
                      ),
                    ),
                    _Figure(value: now, caption: 'now'),
                    if (!refused) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Icon(Icons.arrow_forward, color: Brand.muted),
                      ),
                      _Figure(value: after, caption: 'after'),
                    ],
                  ],
                ),
              ),
            ),
            if (refused)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Only $now in stock, so taking $count out will be refused.',
                  style: const TextStyle(color: Brand.bad, fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 20),
            BigButton(
              label: out ? 'Take $count out' : 'Put $count in',
              onPressed: () => Navigator.of(context).pop(out ? -count : count),
            ),
          ],
        ),
      ),
    );
  }
}

/// A stock number with a small word under it ("now", "after").
class _Figure extends StatelessWidget {
  final int value;
  final String caption;
  const _Figure({required this.value, required this.caption});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '$value',
        style: const TextStyle(fontFamily: Brand.mono, fontSize: 24, fontWeight: FontWeight.w600, height: 1.1),
      ),
      Text(caption, style: const TextStyle(fontSize: 12, color: Brand.muted)),
    ],
  );
}

/// Names a bottom sheet for screen readers, in place of the toolkit's generic "Dialog".
/// (The app's localizations give the sheet's own route no name, see [BrandLocalizations].)
class SheetName extends StatelessWidget {
  final String name;
  final Widget child;
  const SheetName(this.name, {super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      Semantics(scopesRoute: true, namesRoute: true, explicitChildNodes: true, label: name, child: child);
}

class _Toggle extends StatelessWidget {
  final bool out;
  final ValueChanged<bool> onChanged;
  const _Toggle({required this.out, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget half(String label, bool value) {
      final on = out == value;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          child: InkWell(
            onTap: () => onChanged(value),
            child: Container(
              height: 52,
              alignment: Alignment.center,
              color: on ? Brand.ink : Brand.surface,
              child: Text(
                label,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: on ? Brand.paper : Brand.ink),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: Brand.ink, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [half('Take out', true), half('Put in', false)]),
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _Step({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onTap,
    icon: Icon(icon, size: 28),
    style: IconButton.styleFrom(
      fixedSize: const Size(56, 56),
      foregroundColor: Brand.ink,
      backgroundColor: Brand.surface,
      disabledForegroundColor: Brand.muted.withValues(alpha: .5),
      disabledBackgroundColor: Brand.disabled,
      side: BorderSide(color: onTap == null ? Brand.disabled : Brand.ink, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

/// The item's code as it is printed on the shelf label.
class IdTag extends StatelessWidget {
  final String id;
  const IdTag(this.id, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: Brand.ink.withValues(alpha: .35)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      id,
      style: const TextStyle(fontFamily: Brand.mono, fontSize: 13, fontWeight: FontWeight.w500, color: Brand.ink),
    ),
  );
}

class _LowTag extends StatelessWidget {
  const _LowTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: Brand.amber, borderRadius: BorderRadius.circular(4)),
    // Printed in capitals like the dashboard's tag, read aloud as a word rather than spelled out.
    child: const Text(
      'LOW',
      semanticsLabel: 'Low',
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: .6, color: Brand.ink),
    ),
  );
}

class _ItemRow extends StatelessWidget {
  final Item item;
  final List<int> waiting; // the changes of this item's scans still waiting on the phone, oldest first
  final VoidCallback onTap;
  const _ItemRow({required this.item, required this.waiting, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
    color: Brand.surface,
    child: InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Brand.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IdTag(item.id),
                      if (item.low) const _LowTag(),
                      if (waiting.isNotEmpty)
                        // One run of text with the icon inside, so it wraps on a narrow screen or with large text.
                        Text.rich(
                          TextSpan(
                            children: [
                              const WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Padding(
                                  padding: EdgeInsets.only(right: 3),
                                  child: Icon(Icons.schedule, size: 15, color: Brand.muted),
                                ),
                              ),
                              TextSpan(text: 'includes ${waiting.length} not sent yet'),
                            ],
                          ),
                          style: const TextStyle(fontSize: 13, color: Brand.muted),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // The count the worker will see once the waiting scans are sent, the same number the sheet starts from.
            Text(
              '${projected(item.qty, waiting)}',
              style: const TextStyle(fontFamily: Brand.mono, fontWeight: FontWeight.w600, fontSize: 30, height: 1),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LogRow extends StatelessWidget {
  final int delta;
  final String name, detail, when;
  final IconData icon;
  final Color iconColor;
  final bool struck; // refused: the change did not happen
  const _LogRow({
    required this.delta,
    required this.name,
    required this.detail,
    required this.when,
    required this.icon,
    required this.iconColor,
    this.struck = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    decoration: const BoxDecoration(
      color: Brand.surface,
      border: Border(bottom: BorderSide(color: Brand.line)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 10),
        SizedBox(
          width: 44,
          child: Text(
            signed(delta),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFamily: Brand.mono,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              color: struck ? Brand.muted : (delta > 0 ? Brand.ok : Brand.bad),
              decoration: struck ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              Text(detail, style: const TextStyle(fontSize: 14, color: Brand.muted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(when, style: const TextStyle(fontSize: 13, color: Brand.muted)),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  final String title;
  final String? trailing;
  const _Section(this.title, {this.trailing});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1, color: Brand.muted);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Brand.line)),
      ),
      child: Row(
        children: [
          Text(title.toUpperCase(), style: style),
          const Spacer(),
          if (trailing != null) Text(trailing!.toUpperCase(), style: style),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(text, style: const TextStyle(fontSize: 15, color: Brand.muted)),
  );
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final Widget? action;
  const _Banner({required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      color: Brand.ink2,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Brand.amber, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Brand.paper, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(body, style: const TextStyle(color: Color(0xFFD9D5CC), fontSize: 14)),
              ],
            ),
          ),
          ?action,
        ],
      ),
    ),
  );
}

/// Always in the app bar: Online, Sending 2, No signal, 1 waiting, and so on.
class StatusPill extends StatelessWidget {
  final StaffLogic logic;
  const StatusPill({super.key, required this.logic});

  @override
  Widget build(BuildContext context) {
    final n = logic.waiting.length;
    final (label, icon, color) = switch (logic.online) {
      _ when logic.needsKey => ('Key refused', Icons.key_off_outlined, Brand.amber),
      _ when logic.serverError => ('Server error', Icons.error_outline, Brand.amber),
      true => (n == 0 ? 'Online' : 'Sending $n', Icons.cloud_done_outlined, const Color(0xFF7FD3A4)),
      false => ('No signal', Icons.cloud_off, Brand.amber),
      null => ('Connecting', Icons.cloud_queue, const Color(0xFFD9D5CC)),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF4A4F57)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Brand.paper),
          ),
        ],
      ),
    );
  }
}

class _NameChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _NameChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final initials = parts.isEmpty ? '?' : parts.take(2).map((p) => p.characters.first.toUpperCase()).join();
    return Semantics(
      button: true,
      label: 'Signed in as $name. Change name or staff key',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Signed in as $name. Tap to change',
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: CircleAvatar(
                radius: 17,
                backgroundColor: Brand.paper,
                foregroundColor: Brand.ink,
                child: Text(initials, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Always at the top in visitor mode: says this is practice stock, and holds the pretend
/// "No signal" switch and the way out.
class VisitorBanner extends StatelessWidget {
  final StaffLogic logic;
  const VisitorBanner({super.key, required this.logic});

  @override
  Widget build(BuildContext context) {
    final overlay = WidgetStateProperty.resolveWith<Color?>(
      (s) => s.contains(WidgetState.focused) || s.contains(WidgetState.pressed)
          ? Brand.ink.withValues(alpha: .18)
          : s.contains(WidgetState.hovered)
          ? Brand.ink.withValues(alpha: .08)
          : null,
    );
    return Material(
      color: Brand.amber,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.science_outlined, color: Brand.ink, size: 22),
                const SizedBox(width: 10),
                // Inside the Try it page the dashboard beside the phone says the real stock is not affected.
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: 'Practice stock',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (!logic.embedded)
                          const TextSpan(text: ': your own copies of the three items. The real stock is not affected.'),
                      ],
                    ),
                    style: const TextStyle(color: Brand.ink, fontSize: 15, height: 1.3),
                  ),
                ),
                if (!logic.embedded)
                  TextButton(
                    onPressed: logic.leaveVisitor,
                    style: ButtonStyle(
                      foregroundColor: const WidgetStatePropertyAll(Brand.ink),
                      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                      overlayColor: overlay,
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(
                          fontFamily: Brand.sans,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    child: const Text('Leave practice'),
                  ),
              ],
            ),
            SwitchListTile(
              value: logic.noSignal,
              onChanged: logic.setNoSignal,
              contentPadding: const EdgeInsets.only(right: 8),
              secondary: const Icon(Icons.signal_cellular_off, color: Brand.ink),
              title: const Text(
                'No signal',
                style: TextStyle(color: Brand.ink, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('Pretend the phone is offline', style: TextStyle(color: Brand.ink, fontSize: 14)),
              overlayColor: overlay,
              tileColor: Brand.amber,
              hoverColor: Brand.ink.withValues(alpha: .08),
              // An ink outline and thumb on amber: the switch's position, not its colour, says on or off.
              thumbColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Brand.amber : Brand.ink,
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Brand.ink : Brand.paper,
              ),
              trackOutlineColor: const WidgetStatePropertyAll(Brand.ink),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown once, the first time visitor mode starts: three short steps that show what the app is for.
class VisitorGuide extends StatelessWidget {
  final VoidCallback onDone;
  const VisitorGuide({super.key, required this.onDone});

  static const steps = [
    'Tap Work gloves and take 6 out. Here a tap stands for scanning the item\'s shelf label.',
    'Turn on No signal and take 1 more out. The scan waits on the phone.',
    'Turn the signal back on. The waiting scan is sent and counted once.',
  ];

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
    decoration: BoxDecoration(
      color: Brand.surface,
      border: Border.all(color: Brand.ink, width: 1.5),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: const Text('Try this', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 10),
        for (final (n, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10, right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Brand.amber, borderRadius: BorderRadius.circular(5)),
                  child: Text(
                    '${n + 1}',
                    style: const TextStyle(fontFamily: Brand.mono, fontWeight: FontWeight.w600, color: Brand.ink),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(step, style: const TextStyle(fontSize: 15, height: 1.35))),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: onDone,
            style: TextButton.styleFrom(
              foregroundColor: Brand.ink,
              minimumSize: const Size(64, 48),
              textStyle: const TextStyle(fontFamily: Brand.sans, fontWeight: FontWeight.w700, fontSize: 15),
            ),
            child: const Text('Got it'),
          ),
        ),
      ],
    ),
  );
}
