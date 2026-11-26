/// Typed views of the herdr-core (`hc`) API used by shellherd: the core of
/// the Herdr desktop app, protocol generation 1.
///
/// Parsers keep only the fields the app uses and ignore unknown fields. A
/// missing required field or a wrong type raises [HerdrProtocolException].
library;

import 'herdr_errors.dart';
import 'json_fields.dart';

/// The `hello` reply.
class HcHello {
  const HcHello({required this.version, required this.generation});

  factory HcHello.fromJson(Map<String, Object?> j) => HcHello(
    version: jsonField<String>(j, 'version'),
    generation: jsonField<int>(j, 'generation'),
  );

  final String version;
  final int generation;
}

/// What a program says it is doing, through OSC 7501.
class HcStatus {
  const HcStatus({required this.state, this.app, this.msg});

  factory HcStatus.fromJson(Map<String, Object?> j) => HcStatus(
    state: jsonField<String>(j, 'state'),
    app: jsonOptional<String>(j, 'app'),
    msg: jsonOptional<String>(j, 'msg'),
  );

  /// `idle`, `working`, `done`, `blocked` or `error`, in the program's own
  /// words.
  final String state;

  /// The reporting program, for example `claude-code`.
  final String? app;

  /// What it is doing now.
  final String? msg;
}

/// One terminal of the core: `t7`.
class HcTerminal {
  const HcTerminal({
    required this.address,
    required this.live,
    required this.cwd,
    required this.title,
    required this.labels,
    required this.turn,
    this.name,
    this.status,
    this.parent,
    this.foregroundPid,
  });

  factory HcTerminal.fromJson(Map<String, Object?> j) {
    final foreground = jsonOptional<Map<String, Object?>>(j, 'foreground');
    final status = jsonOptional<Map<String, Object?>>(j, 'status');
    return HcTerminal(
      address: jsonField<String>(j, 'address'),
      live: jsonField<String>(j, 'state') == 'live',
      // Where it is now; the launch folder when the core does not know.
      cwd: switch (foreground) {
        final f? => jsonField<String>(f, 'cwd'),
        null => jsonField<String>(j, 'cwd'),
      },
      title: jsonOptional<String>(j, 'title') ?? '',
      labels: _labels(jsonField<Map<String, Object?>>(j, 'labels')),
      turn: jsonOptional<int>(j, 'turn') ?? 0,
      name: jsonOptional<String>(j, 'name'),
      status: status == null ? null : HcStatus.fromJson(status),
      parent: jsonOptional<String>(j, 'parent'),
      foregroundPid: foreground == null
          ? null
          : jsonOptional<int>(foreground, 'pid'),
    );
  }

  final String address;

  /// False once the program has finished.
  final bool live;
  final String cwd;

  /// The terminal title the program set; empty without one.
  final String title;

  /// Free-form `key=value` labels. The Herdr app sets [spaceLabel],
  /// [tabLabel], [seenLabel] and [whereLabel].
  final Map<String, String> labels;

  /// Goes up each time the status leaves `working`.
  final int turn;

  /// A name given at start, if any.
  final String? name;

  /// Null while the program does not report one.
  final HcStatus? status;

  /// The terminal that started this one (`t3`).
  final String? parent;

  /// The leader of the process group in front, such as the agent that the
  /// shell started; null once the terminal has finished.
  final int? foregroundPid;

  static const spaceLabel = 'herdr.space';
  static const tabLabel = 'herdr.tab';

  /// The [turn] that a person last looked at in the Herdr app.
  static const seenLabel = 'herdr.seen';

  /// The turn of [seenLabel]; null without one, which is not 0.
  int? get seen => int.tryParse(labels[seenLabel] ?? '');

  /// "space / tab", as the Herdr app names the place.
  static const whereLabel = 'where';
}

Map<String, String> _labels(Map<String, Object?> j) => {
  for (final key in j.keys) key: jsonField<String>(j, key),
};

/// The layout of the Herdr app: the `herdr-app` document of the core.
class HcLayout {
  const HcLayout(this.spaces);

  /// An empty value: the app never wrote the document.
  factory HcLayout.fromJson(Object? value) => switch (value) {
    null => const HcLayout([]),
    final Map<String, Object?> j => HcLayout(
      jsonList(j, 'spaces', HcSpace.fromJson),
    ),
    _ => throw const HerdrProtocolException('the layout is not an object'),
  };

  /// The name of the core document that holds the layout.
  static const document = 'herdr-app';

  final List<HcSpace> spaces;
}

class HcSpace {
  const HcSpace({
    required this.id,
    required this.name,
    required this.folder,
    required this.tabs,
  });

  factory HcSpace.fromJson(Map<String, Object?> j) => HcSpace(
    id: jsonField<String>(j, 'id'),
    name: jsonOptional<String>(j, 'name') ?? '',
    folder: jsonOptional<String>(j, 'folder') ?? '',
    tabs: jsonList(j, 'tabs', HcTab.fromJson),
  );

  final String id;

  /// Empty when nobody named it; the app then names it after its folder.
  final String name;

  /// Where it was made.
  final String folder;
  final List<HcTab> tabs;
}

class HcTab {
  const HcTab({required this.id, required this.name, required this.terminals});

  factory HcTab.fromJson(Map<String, Object?> j) => HcTab(
    id: jsonField<String>(j, 'id'),
    name: jsonOptional<String>(j, 'name') ?? '',
    terminals: switch (jsonOptional<Map<String, Object?>>(j, 'root')) {
      final root? => _terminalsIn(root),
      null => const [],
    },
  );

  final String id;

  /// Empty when nobody named it; the app then calls it by its place.
  final String name;

  /// Addresses of the terminals in its panes, in layout order.
  final List<String> terminals;
}

/// The terminal addresses in a split tree: nodes have `children`, leaves a
/// `content`, which holds `terminal` for a terminal pane (mod panes have
/// none).
List<String> _terminalsIn(Map<String, Object?> node) => [
  if (jsonOptional<Map<String, Object?>>(node, 'content') case final content?)
    ?jsonOptional<String>(content, 'terminal'),
  for (final child in jsonList(node, 'children', (c) => c))
    ..._terminalsIn(child),
];
