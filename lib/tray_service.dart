import 'dart:async';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class TrayService with TrayListener {
  TrayService._();
  static final instance = TrayService._();

  final _storage = const FlutterSecureStorage();
  bool _closeToTray = false;
  bool _autoStart = false;
  bool _initialized = false;
  final _showWindowController = StreamController<void>.broadcast();

  Stream<void> get onShowWindow => _showWindowController.stream;
  bool get closeToTray => _closeToTray;
  bool get autoStart => _autoStart;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _closeToTray = await _storage.read(key: 'close_to_tray') == 'true';
    _autoStart = await _storage.read(key: 'auto_start') == 'true';

    if (_closeToTray) {
      await _showTray();
      await windowManager.setPreventClose(true);
    }
    if (_autoStart) {
      await _enableAutoStart();
    }
  }

  Future<void> setCloseToTray(bool value) async {
    _closeToTray = value;
    await _storage.write(key: 'close_to_tray', value: value.toString());

    if (value) {
      await _showTray();
      await windowManager.setPreventClose(true);
    } else {
      await _hideTray();
      await windowManager.setPreventClose(false);
    }
  }

  Future<void> setAutoStart(bool value) async {
    _autoStart = value;
    await _storage.write(key: 'auto_start', value: value.toString());

    if (value) {
      await _enableAutoStart();
    } else {
      await _disableAutoStart();
    }
  }

  Future<void> handleWindowClose() async {
    if (_closeToTray) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _showTray() async {
    trayManager.addListener(this);

    if (Platform.isLinux) {
      await trayManager.setIcon('assets/tray_icon.png');
    } else if (Platform.isMacOS) {
      await trayManager.setIcon('assets/tray_icon.png');
    }

    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(label: 'Show Window', onClick: (_) => showWindow()),
          MenuItem(label: 'Quit', onClick: (_) => _forceQuit()),
        ],
      ),
    );
  }

  Future<void> _hideTray() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  Future<void> _forceQuit() async {
    await _hideTray();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> _enableAutoStart() async {
    try {
      if (Platform.isLinux) {
        await _createLinuxAutostart();
      } else if (Platform.isMacOS) {
        await _createMacAutostart();
      }
    } catch (_) {}
  }

  Future<void> _disableAutoStart() async {
    try {
      if (Platform.isLinux) {
        await _removeLinuxAutostart();
      } else if (Platform.isMacOS) {
        await _removeMacAutostart();
      }
    } catch (_) {}
  }

  Future<void> _createLinuxAutostart() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final dir = Directory('$home/.config/autostart');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/cloudflare-manager.desktop');
    final exe = Platform.resolvedExecutable;
    await file.writeAsString('''
[Desktop Entry]
Type=Application
Name=Cloudflare Manager
Exec=$exe
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
''');
  }

  Future<void> _removeLinuxAutostart() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final file = File('$home/.config/autostart/cloudflare-manager.desktop');
    if (await file.exists()) await file.delete();
  }

  Future<void> _createMacAutostart() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final plistDir = Directory('$home/Library/LaunchAgents');
    if (!await plistDir.exists()) await plistDir.create(recursive: true);
    final file = File('${plistDir.path}/com.cloudflare.manager.plist');
    final exe = Platform.resolvedExecutable;
    await file.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.manager</string>
    <key>ProgramArguments</key>
    <array>
        <string>$exe</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
''');
  }

  Future<void> _removeMacAutostart() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final file = File('$home/Library/LaunchAgents/com.cloudflare.manager.plist');
    if (await file.exists()) await file.delete();
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {}
}
