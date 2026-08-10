/// The seam between the CAT protocol and whatever is carrying it.
///
/// Nothing behind this interface may assume a serial port. The Flutter app
/// adds a `TcpTransport` (rigctld) and an Android `usb_serial` transport
/// against this same contract.
library;

/// A bidirectional CAT link.
abstract class CatTransport {
  /// Opens the link. Throws [CatTransportException] if it cannot be opened.
  Future<void> open();

  /// Closes the link. Safe to call when already closed.
  Future<void> close();

  /// Complete responses, already split on `;` with the `;` stripped.
  ///
  /// Broadcast: the controller subscribes, and a recording decorator may tee.
  Stream<String> get lines;

  /// Sends a command. The caller supplies the trailing `;`.
  ///
  /// Fire-and-forget by design — matching responses to commands is the
  /// controller's job, because only it knows what is in flight.
  void send(String command);

  bool get isOpen;
}

/// Raised when a transport cannot be opened or has failed.
class CatTransportException implements Exception {
  const CatTransportException(this.message, {this.remedy});

  final String message;

  /// An actionable next step to show the operator, when one exists.
  final String? remedy;

  @override
  String toString() =>
      remedy == null ? 'CatTransportException: $message' : '$message\n\n$remedy';
}
