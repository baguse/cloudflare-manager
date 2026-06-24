import 'dart:convert';
import 'dart:io';

class AppStorage {
  static final AppStorage instance = AppStorage._();
  AppStorage._();

  File get _file {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return File('$home/.cloudflared/app-settings.json');
  }

  Future<Map<String, dynamic>> _readAll() async {
    try {
      if (await _file.exists()) {
        final content = await _file.readAsString();
        if (content.isNotEmpty) {
          final data = json.decode(content);
          if (data is Map<String, dynamic>) return data;
        }
      }
    } catch (_) {}
    return {};
  }

  Future<void> _writeAll(Map<String, dynamic> data) async {
    final dir = _file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    await _file.writeAsString(json.encode(data));
  }

  Future<String?> read({required String key}) async {
    final data = await _readAll();
    return data[key]?.toString();
  }

  Future<void> write({required String key, required String? value}) async {
    final data = await _readAll();
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
    await _writeAll(data);
  }

  Future<void> delete({required String key}) async {
    final data = await _readAll();
    data.remove(key);
    await _writeAll(data);
  }
}
