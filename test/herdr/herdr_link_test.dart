import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/herdr_link.dart';

void main() {
  group('herdrSocketPath', () {
    test('default and named sessions', () {
      expect(herdrSocketPath('/h/.config'), '/h/.config/herdr/herdr.sock');
      expect(
        herdrSocketPath('/h/.config', session: 'work'),
        '/h/.config/herdr/sessions/work/herdr.sock',
      );
    });

    test('rejects names that leave the sessions directory', () {
      for (final bad in ['', '.', '..', 'a/b', '../x']) {
        expect(
          () => herdrSocketPath('/h/.config', session: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });
}
