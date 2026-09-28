import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/tmux_config_service.dart';

void main() {
  group('supportsTerminalFeatures', () {
    test('returns false for tmux 3.0a', () {
      expect(supportsTerminalFeatures('tmux 3.0a'), isFalse);
    });

    test('returns true for tmux 3.2 and newer', () {
      expect(supportsTerminalFeatures('tmux 3.2'), isTrue);
      expect(supportsTerminalFeatures('tmux 3.4'), isTrue);
    });
  });

  group('buildTmuxConfig', () {
    test('uses terminal-overrides for old tmux', () {
      final config = buildTmuxConfig('tmux 3.0a');

      expect(config, contains('terminal-overrides'));
      expect(config,
          isNot(contains('terminal-features ",xterm-256color:clipboard"')));
    });

    test('uses terminal-features for newer tmux', () {
      final config = buildTmuxConfig('tmux 3.4');

      expect(config, contains('terminal-features ",xterm-256color:clipboard"'));
      expect(config, isNot(contains('terminal-overrides')));
    });
  });

  group('tmuxConfigMatchesClipboardTransport', () {
    test('matches version-specific clipboard transport', () {
      expect(
        tmuxConfigMatchesClipboardTransport(
          buildTmuxConfig('tmux 3.0a'),
          'tmux 3.0a',
        ),
        isTrue,
      );
      expect(
        tmuxConfigMatchesClipboardTransport(
          buildTmuxConfig('tmux 3.4'),
          'tmux 3.4',
        ),
        isTrue,
      );
    });
  });
}
