import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'ssh/secret_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices(
    dataDir: await getApplicationSupportDirectory(),
    secrets: SecureSecretStore(),
  );
  runApp(ShellherdApp(services));
}
