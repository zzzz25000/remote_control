import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ble/bluetooth/ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'platform adapter sends binary bytes, selected profile and session token',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ble.remote/methods'), (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      final link = PlatformBleTransport();
      await link.connect('device', 'bt630', 7);
      await link.write(Uint8List.fromList([0xa5, 0x5a]), 7);
      expect(calls[0].arguments, {
        'id': 'device',
        'mode': 'bt630',
        'generation': 7,
      });
      expect(calls[1].arguments['bytes'], [0xa5, 0x5a]);
      expect(calls[1].arguments['generation'], 7);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('ble.remote/methods'),
            null,
          );
    },
  );
}
