import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/notify/notifier.dart';

void main() {
  test('the lock screen shows that an alert came; the phone decides on its text', () {
    expect(
      agentNotificationDetails.android!.visibility,
      NotificationVisibility.private,
    );
  });
}
