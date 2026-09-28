import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/main.dart';

void main() {
  test('macOS keeps polling while inactive; Android uses its background service',
      () {
    expect(shouldPollLocally(TargetPlatform.macOS, false, true), isTrue);
    expect(shouldPollLocally(TargetPlatform.android, false, true), isFalse);
    expect(shouldPollLocally(TargetPlatform.macOS, true, true), isTrue);
    expect(shouldPollLocally(TargetPlatform.macOS, false, false), isFalse);
  });
}
