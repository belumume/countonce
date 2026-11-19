// What the app works with. Plain classes, filled from the API's JSON.

class Item {
  final String id;
  final String name;
  final int qty;
  final int reorderPoint;

  const Item({required this.id, required this.name, required this.qty, required this.reorderPoint});

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        name: j['name'] as String,
        qty: j['qty'] as int,
        reorderPoint: j['reorder_point'] as int,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'qty': qty, 'reorder_point': reorderPoint};

  bool get low => qty <= reorderPoint;
}

/// One scan, waiting in the outbox until the API has answered it.
/// The request id is made once, when the worker scans, and never changes,
/// so sending it again after a lost reply cannot count it twice (rule 2).
class Movement {
  final String requestId;
  final String itemId;
  final int delta; // -1 takes one out, +5 puts five in
  final String staff;
  final DateTime scannedAt;

  const Movement({
    required this.requestId,
    required this.itemId,
    required this.delta,
    required this.staff,
    required this.scannedAt,
  });

  factory Movement.fromJson(Map<String, dynamic> j) => Movement(
        requestId: j['request_id'] as String,
        itemId: j['item_id'] as String,
        delta: j['delta'] as int,
        staff: j['staff'] as String,
        scannedAt: DateTime.parse(j['scanned_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'request_id': requestId,
        'item_id': itemId,
        'delta': delta,
        'staff': staff,
        'scanned_at': scannedAt.toIso8601String(),
      };
}

/// What the API said about one movement.
class Outcome {
  final Movement movement;
  final String result; // applied, refused, or rejected
  final bool repeated; // the API had already applied this request id
  final int? qty; // stock after the movement, when the API says
  final String? reason;
  final DateTime answeredAt;

  const Outcome({
    required this.movement,
    required this.result,
    required this.repeated,
    this.qty,
    this.reason,
    required this.answeredAt,
  });
}
