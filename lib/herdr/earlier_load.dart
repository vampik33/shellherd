/// How far loading the part before what a list shows got: the messages
/// before a chat's transcript read, or the lines above a pane's text.
enum EarlierLoad {
  /// Nothing loads: more can be asked for.
  idle,
  loading,

  /// The last load failed: the user can try again.
  failed,

  /// As much as loads is loaded: no more is.
  capped,

  /// Nothing can load them now, for example before the read found where
  /// its first line starts.
  none,
}
