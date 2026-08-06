import 'dart:math';

const _keyChars =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

/// Generates a cryptographically secure random alphanumeric string.
String randomKeyString(int length) {
  final r = Random.secure();
  return String.fromCharCodes(
    List.generate(length, (_) => _keyChars.codeUnitAt(r.nextInt(_keyChars.length))),
  );
}

/// Generates a new API key in the canonical `cm_<random>_<timestamp>` format.
String generateApiKey() {
  return 'cm_${randomKeyString(32)}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
}
