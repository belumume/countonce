import 'dart:async';

import 'package:flutter/material.dart';

import '../logic.dart';
import 'theme.dart';

/// Name and staff key, asked once. Shown as its own page on first start, and as a sheet when
/// the worker taps their name chip or the API refuses the key.
class SignInForm extends StatefulWidget {
  final StaffLogic logic;
  final String? problem; // why the form is shown again, if it is
  final VoidCallback? onDone;
  const SignInForm({super.key, required this.logic, this.problem, this.onDone});

  @override
  State<SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<SignInForm> {
  // The saved staff name, never "Visitor" from visitor mode.
  late final _name = TextEditingController(text: widget.logic.savedStaff);
  late final _key = TextEditingController(text: widget.logic.key);
  bool _show = false;

  bool get _ready => _name.text.trim().isNotEmpty && _key.text.trim().isNotEmpty;

  bool _saving = false;

  // Saves the name and key, then closes.
  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    await widget.logic.setStaff(_name.text);
    // The key is saved at once; the waiting scans are then sent in the background.
    unawaited(widget.logic.setKey(_key.text));
    if (mounted) widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.problem != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Brand.bad.withValues(alpha: .08),
              border: Border.all(color: Brand.bad),
            ),
            child: Text(
              widget.problem!,
              style: const TextStyle(color: Brand.bad, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Your name',
            helperText: 'Shown next to every change you record.',
            helperMaxLines: 2,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _key,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Staff key',
            helperText: 'Your manager gives you this key. You need it to change the real stock.',
            helperMaxLines: 2,
            suffixIcon: IconButton(
              tooltip: _show ? 'Hide the key' : 'Show the key',
              icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _ready ? _save() : null,
        ),
        const SizedBox(height: 24),
        BigButton(label: 'Start', onPressed: _ready ? _save : null),
      ],
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    super.dispose();
  }
}

class SignInPage extends StatelessWidget {
  final StaffLogic logic;
  const SignInPage({super.key, required this.logic});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            const Mark(size: 56),
            const SizedBox(height: 24),
            Text('CountOnce', style: Theme.of(context).textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'Scan a shelf label to record stock taken out or put in. The app keeps working with no signal.',
              style: TextStyle(fontSize: 16, color: Brand.muted),
            ),
            const SizedBox(height: 32),
            SignInForm(logic: logic),
            const SizedBox(height: 40),
            VisitorButton(logic: logic),
          ],
        ),
      ),
    );
  }
}

/// The app's mark: the shelf label, an amber tag with "1×" printed on it: every action counted once.
class Mark extends StatelessWidget {
  final double size;
  const Mark({super.key, this.size = 30});

  @override
  // Decoration only: the name "CountOnce" or "Stock" sits beside it, so screen readers skip it.
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Brand.amber, borderRadius: BorderRadius.circular(size * .2)),
        child: Text(
          '1×',
          style: TextStyle(fontFamily: Brand.mono, fontWeight: FontWeight.w600, fontSize: size * .45, color: Brand.ink),
        ),
      ),
    ),
  );
}

/// The one main action on a screen: amber, full width, 56 high, easy to hit with a gloved thumb.
class BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  const BigButton({super.key, required this.label, this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 24),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: Brand.amber,
      foregroundColor: Brand.ink,
      disabledBackgroundColor: Brand.disabled,
      disabledForegroundColor: Brand.muted,
      minimumSize: const Size.fromHeight(56),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: const TextStyle(fontFamily: Brand.sans, fontWeight: FontWeight.w700, fontSize: 18),
    ),
  );
}

/// The way in for a public visitor: secondary to the staff sign-in, with one line saying what it does.
class VisitorButton extends StatefulWidget {
  final StaffLogic logic;
  const VisitorButton({super.key, required this.logic});

  @override
  State<VisitorButton> createState() => _VisitorButtonState();
}

class _VisitorButtonState extends State<VisitorButton> {
  bool _starting = false;

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    await widget.logic.startVisitor();
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Said before the button it explains, so it is read first on screen and by a screen reader.
      const Text(
        'No staff key? Practise on three items of your own. The real stock is not affected.',
        style: TextStyle(fontSize: 15, color: Brand.muted),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _starting ? null : _start,
        icon: const Icon(Icons.science_outlined, size: 22),
        label: const Text('Try it without a key'),
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(Brand.ink),
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(52)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontFamily: Brand.sans, fontWeight: FontWeight.w700, fontSize: 17),
          ),
          // A thicker border shows where the keyboard focus is.
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(color: Brand.ink, width: s.contains(WidgetState.focused) ? 3 : 1.5),
          ),
          overlayColor: WidgetStatePropertyAll(Brand.ink.withValues(alpha: .08)),
        ),
      ),
    ],
  );
}
