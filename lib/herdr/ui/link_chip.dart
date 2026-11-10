import '../../ui/link_status.dart';
import '../../ui/palette.dart';
import '../herdr_connection.dart';

/// The chip for the state of a herdr link.
LinkChip herdrLinkChip(LinkState state) => switch (state) {
  LinkOffline() => const LinkChip('offline', Mocha.overlay),
  LinkConnecting() => const LinkChip('connecting', Mocha.yellow),
  LinkSyncing() => const LinkChip('syncing', Mocha.yellow),
  LinkLive() => const LinkChip('live', Mocha.green),
  LinkReconnecting() => const LinkChip('retrying', Mocha.yellow),
  LinkNoServer() => const LinkChip('no herdr', Mocha.red),
  LinkFailed() => const LinkChip('failed', Mocha.red),
};
