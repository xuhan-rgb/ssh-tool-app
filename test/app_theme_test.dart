import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppTheme.select('dark'));

  test('light palette updates surfaces, text, and status colors', () {
    AppTheme.select('light');

    expect(AppTheme.darkTheme.brightness, Brightness.light);
    expect(AppTheme.bgDeep, const Color(0xFFFFFFFF));
    expect(AppTheme.textPrimary, const Color(0xFF17212F));
    expect(AppTheme.greenDim,
        AppTheme.green.withValues(alpha: 0.15));

    AppTheme.select('violet');
    expect(AppTheme.darkTheme.brightness, Brightness.dark);
    expect(AppTheme.greenDim,
        AppTheme.green.withValues(alpha: 0.15));
  });
}
