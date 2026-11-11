import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/herdr_link.dart';

void main() {
  group('herdrSocketPath', () {
    test('default and named sessions', () {
      expect(herdrSocketPath('/h/.config'), '/h/.config/herdr/herdr.sock');
      expect(
        herdrSocketPath('/h/.config', session: 'default'),
        '/h/.config/herdr/herdr.sock',
        reason: 'herdr keeps "default" at the top, not under sessions',
      );
      expect(
        herdrSocketPath('/h/.config', session: '${'a' * 62}.-'),
        '/h/.config/herdr/sessions/${'a' * 62}.-/herdr.sock',
      );
      expect(
        herdrSocketPath('/h/.config', session: 'work'),
        '/h/.config/herdr/sessions/work/herdr.sock',
      );
    });

    test('rejects the names herdr refuses', () {
      for (final bad in [
        '',
        '.',
        '..',
        'a/b',
        '../x',
        'a b',
        'work\n',
        'été',
        r'$x',
        'a' * 65,
      ]) {
        expect(
          () => herdrSocketPath('/h/.config', session: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });
}
