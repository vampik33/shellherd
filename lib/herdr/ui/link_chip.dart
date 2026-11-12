import '../../ui/link_status.dart';
import '../../ui/palette.dart';
import '../herdr_connection.dart';

/// The chip for the state of a herdr link.
LinkChip herdrLinkChip(LinkState state) => switch (state) {
  LinkOffline() => const LinkChip('offline', Graphite.dim),
  LinkConnecting() => const LinkChip('connecting', Graphite.yellow),
  LinkSyncing() => const LinkChip('syncing', Graphite.yellow),
  LinkLive() => const LinkChip('live', Graphite.green),
  LinkReconnecting() => const LinkChip('retrying', Graphite.yellow),
  LinkNoServer() => const LinkChip('no herdr', Graphite.red),
  LinkFailed() => const LinkChip('failed', Graphite.red),
};
