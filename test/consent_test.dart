import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithra_flutter_sdk/mithra_flutter_sdk.dart';
import 'package:mithra_flutter_sdk/src/channels.dart';

// Covers the consent wire contract: `NaryaConfiguration.startsOptedOut` on the
// initialize payload, and the `setOptOut` / `optOut` method pair.
//
// Everything consent actually *does* - suppressing events, dropping the queued
// batches, persisting the decision across launches - happens inside the native
// SDKs and is covered there (narya-ios `ConsentTests`, narya-android
// `ConsentTest`). What can go wrong on this side is the wire form, so that is
// what these assert: a key the native codec does not recognise silently falls
// back to its default, which would leave a host that asked to start opted out
// collecting from launch with no error anywhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('consent', () {
    final List<MethodCall> calls = <MethodCall>[];
    bool nativeOptOut = false;

    setUp(() {
      calls.clear();
      nativeOptOut = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(NaryaChannels.methods),
            (MethodCall call) async {
              calls.add(call);
              switch (call.method) {
                case 'setOptOut':
                  final Map<Object?, Object?> arguments =
                      call.arguments as Map<Object?, Object?>;
                  nativeOptOut = (arguments['optOut'] as bool?) ?? false;
                  return null;
                case 'optOut':
                  return nativeOptOut;
                default:
                  return null;
              }
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(NaryaChannels.methods),
            null,
          );
    });

    Map<Object?, Object?> configurationOf(MethodCall call) =>
        (call.arguments as Map<Object?, Object?>)['configuration']
            as Map<Object?, Object?>;

    test('startsOptedOut defaults to false on initialize', () async {
      await Narya.initialize(const NaryaConfiguration(writeKey: 'key'));

      expect(configurationOf(calls.single)['startsOptedOut'], isFalse);
    });

    test('startsOptedOut reaches native when set', () async {
      await Narya.initialize(
        const NaryaConfiguration(writeKey: 'key', startsOptedOut: true),
      );

      expect(configurationOf(calls.single)['startsOptedOut'], isTrue);
    });

    test('setOptOut sends the decision', () async {
      await Narya.setOptOut(true);

      expect(calls.single.method, 'setOptOut');
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['optOut'],
        isTrue,
      );
    });

    test('optOut reads the decision back from native', () async {
      expect(await Narya.optOut, isFalse);

      await Narya.setOptOut(true);
      expect(await Narya.optOut, isTrue);

      await Narya.setOptOut(false);
      expect(await Narya.optOut, isFalse);
    });

    test('optOut is false when native answers null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(NaryaChannels.methods),
            (MethodCall call) async => null,
          );

      // A null answer means "no native instance yet", which is not the same as
      // opted out. Reporting it as opted out would be the more alarming lie.
      expect(await Narya.optOut, isFalse);
    });
  });
}
