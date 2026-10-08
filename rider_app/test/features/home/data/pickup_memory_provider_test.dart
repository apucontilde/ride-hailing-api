import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/features/home/data/pickup_memory_provider.dart';
import 'package:rider_app/features/home/model/place.dart';

const _place = Place(
  id: 'p1',
  name: 'Pickup Point',
  address: 'Main St',
  lat: 9.9281,
  lng: -84.0907,
);

void main() {
  test('starts empty: no pickup and no pending return', () {
    final notifier = PickupMemoryNotifier();

    expect(notifier.state.manualPickup, isNull);
    expect(notifier.state.restoreOnHome, isNull);
  });

  test('remember stores the manual place and keeps the pending intent', () {
    final notifier = PickupMemoryNotifier()
      ..markReturning(restorePickup: true)
      ..remember(_place);

    expect(notifier.state.manualPickup, _place);
    expect(notifier.state.restoreOnHome, isTrue);
  });

  test('a null manual pickup is distinguishable from no trip', () {
    final notifier = PickupMemoryNotifier()..remember(null);

    // `remember(null)` records a real trip that started from the device fix;
    // there is still no pending return until `markReturning`.
    expect(notifier.state.manualPickup, isNull);
    expect(notifier.state.restoreOnHome, isNull);

    notifier.markReturning(restorePickup: false);
    expect(notifier.state.restoreOnHome, isFalse);
    expect(notifier.state.manualPickup, isNull);
  });

  test('consumeReturn returns the intent once, keeps the pickup and clears it',
      () {
    final notifier = PickupMemoryNotifier()
      ..remember(_place)
      ..markReturning(restorePickup: true);

    final first = notifier.consumeReturn();
    expect(first.manualPickup, _place);
    expect(first.restoreOnHome, isTrue);
    // The intent is cleared but the pickup is retained for the restore.
    expect(notifier.state.restoreOnHome, isNull);
    expect(notifier.state.manualPickup, _place);

    final second = notifier.consumeReturn();
    expect(second.restoreOnHome, isNull);
  });

  test('clear empties the whole memory', () {
    final notifier = PickupMemoryNotifier()
      ..remember(_place)
      ..markReturning(restorePickup: true)
      ..clear();

    expect(notifier.state.manualPickup, isNull);
    expect(notifier.state.restoreOnHome, isNull);
  });
}
