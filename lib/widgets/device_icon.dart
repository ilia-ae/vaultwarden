import 'package:flutter/material.dart';

/// What kind of client sent a "Login with device" request.
enum DeviceKind {
  android,
  ios,
  browser,
  extension,
  desktop,
  cli,
  server,
  unknown
}

/// Browser family, when the requesting client is a browser or extension.
enum BrowserBrand {
  chrome,
  edge,
  safari,
  firefox,
  opera,
  brave,
  vivaldi,
  internetExplorer,
  duckDuckGo,
}

/// Desktop operating system of a desktop app or CLI.
enum DesktopOs { windows, macos, linux }

/// A requesting device, classified from the server's device type name
/// (`requestDeviceType`, e.g. "Chrome", "Firefox Extension", "macOS CLI") and,
/// when the server sends it (bitwarden.com), the numeric Bitwarden
/// `DeviceType` (`requestDeviceTypeValue`).
@immutable
class DeviceDescriptor {
  const DeviceDescriptor(this.kind, {this.brand, this.os});

  final DeviceKind kind;
  final BrowserBrand? brand;
  final DesktopOs? os;

  @override
  bool operator ==(Object other) =>
      other is DeviceDescriptor &&
      other.kind == kind &&
      other.brand == brand &&
      other.os == os;

  @override
  int get hashCode => Object.hash(kind, brand, os);

  @override
  String toString() => 'DeviceDescriptor($kind, $brand, $os)';
}

/// Bitwarden `DeviceType` values (bitwarden/server Core/Enums/DeviceType.cs).
const Map<int, DeviceDescriptor> _byTypeValue = {
  0: DeviceDescriptor(DeviceKind.android),
  1: DeviceDescriptor(DeviceKind.ios),
  2: DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.chrome),
  3: DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.firefox),
  4: DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.opera),
  5: DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.edge),
  6: DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.windows),
  7: DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.macos),
  8: DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.linux),
  9: DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.chrome),
  10: DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.firefox),
  11: DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.opera),
  12: DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.edge),
  13: DeviceDescriptor(
    DeviceKind.browser,
    brand: BrowserBrand.internetExplorer,
  ),
  14: DeviceDescriptor(DeviceKind.browser),
  15: DeviceDescriptor(DeviceKind.android),
  16: DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.windows),
  17: DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.safari),
  18: DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.vivaldi),
  19: DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.vivaldi),
  20: DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.safari),
  21: DeviceDescriptor(DeviceKind.server),
  22: DeviceDescriptor(DeviceKind.server),
  23: DeviceDescriptor(DeviceKind.cli, os: DesktopOs.windows),
  24: DeviceDescriptor(DeviceKind.cli, os: DesktopOs.macos),
  25: DeviceDescriptor(DeviceKind.cli, os: DesktopOs.linux),
  26: DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.duckDuckGo),
  27: DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.duckDuckGo),
};

BrowserBrand? _brandIn(String s) {
  if (s.contains('edge')) return BrowserBrand.edge;
  if (s.contains('chrome') || s.contains('chromium')) {
    return BrowserBrand.chrome;
  }
  if (s.contains('firefox')) return BrowserBrand.firefox;
  if (s.contains('safari')) return BrowserBrand.safari;
  if (s.contains('opera')) return BrowserBrand.opera;
  if (s.contains('brave')) return BrowserBrand.brave;
  if (s.contains('vivaldi')) return BrowserBrand.vivaldi;
  if (s.contains('duckduckgo')) return BrowserBrand.duckDuckGo;
  if (s.contains('internet explorer') || RegExp(r'\bie\b').hasMatch(s)) {
    return BrowserBrand.internetExplorer;
  }
  return null;
}

DesktopOs? _osIn(String s) {
  if (s.contains('windows') || s.contains('uwp')) return DesktopOs.windows;
  if (s.contains('macos') || s.contains('mac os') || s.contains('osx')) {
    return DesktopOs.macos;
  }
  if (s.contains('linux')) return DesktopOs.linux;
  return null;
}

/// Classifies a requesting device. [typeValue] (bitwarden.com) wins over the
/// name; Vaultwarden sends only the name ("Chrome", "Windows", "macOS CLI"…).
DeviceDescriptor describeDevice(String name, [int? typeValue]) {
  final byValue = typeValue == null ? null : _byTypeValue[typeValue];
  if (byValue != null) return byValue;

  final s = name.toLowerCase();
  if (RegExp(r'\bcli\b').hasMatch(s)) {
    return DeviceDescriptor(DeviceKind.cli, os: _osIn(s));
  }
  final brand = _brandIn(s);
  if (s.contains('extension')) {
    return DeviceDescriptor(DeviceKind.extension, brand: brand);
  }
  if (brand != null) return DeviceDescriptor(DeviceKind.browser, brand: brand);
  if (s.contains('android')) return const DeviceDescriptor(DeviceKind.android);
  if (RegExp(r'\bios\b').hasMatch(s) ||
      s.contains('iphone') ||
      s.contains('ipad')) {
    return const DeviceDescriptor(DeviceKind.ios);
  }
  if (s.contains('browser') || RegExp(r'\bweb\b').hasMatch(s)) {
    return const DeviceDescriptor(DeviceKind.browser);
  }
  final os = _osIn(s);
  if (os != null || s.contains('desktop')) {
    return DeviceDescriptor(DeviceKind.desktop, os: os);
  }
  if (s.contains('server') || RegExp(r'\bsdk\b').hasMatch(s)) {
    return const DeviceDescriptor(DeviceKind.server);
  }
  return const DeviceDescriptor(DeviceKind.unknown);
}

/// Material icon for a requesting device (A12).
IconData deviceIconFor(String name, [int? typeValue]) {
  final d = describeDevice(name, typeValue);
  return switch (d.kind) {
    DeviceKind.android => Icons.phone_android,
    DeviceKind.ios => Icons.phone_iphone,
    DeviceKind.browser => Icons.language,
    DeviceKind.extension => Icons.extension_outlined,
    DeviceKind.cli => Icons.terminal,
    DeviceKind.server => Icons.dns_outlined,
    DeviceKind.desktop => switch (d.os) {
        DesktopOs.windows => Icons.desktop_windows_outlined,
        DesktopOs.macos => Icons.laptop_mac,
        _ => Icons.computer,
      },
    DeviceKind.unknown => Icons.devices,
  };
}

/// Accent colour of a browser family, used to tint its icon tile.
Color? browserBrandColor(BrowserBrand? brand) => switch (brand) {
      BrowserBrand.chrome => const Color(0xFF1A73E8),
      BrowserBrand.edge => const Color(0xFF0C8CE9),
      BrowserBrand.safari => const Color(0xFF1E90FF),
      BrowserBrand.firefox => const Color(0xFFFF7139),
      BrowserBrand.opera => const Color(0xFFFF1B2D),
      BrowserBrand.brave => const Color(0xFFFB542B),
      BrowserBrand.vivaldi => const Color(0xFFEF3939),
      BrowserBrand.internetExplorer => const Color(0xFF1EBBEE),
      BrowserBrand.duckDuckGo => const Color(0xFFDE5833),
      null => null,
    };

/// Rounded tile with the device's icon; browsers and extensions are tinted
/// with their brand colour, everything else with the theme's primary colour.
class DeviceIcon extends StatelessWidget {
  const DeviceIcon({
    super.key,
    required this.deviceName,
    this.typeValue,
    this.size = 40,
  });

  final String deviceName;
  final int? typeValue;
  final double size;

  @override
  Widget build(BuildContext context) {
    final d = describeDevice(deviceName, typeValue);
    final color =
        browserBrandColor(d.brand) ?? Theme.of(context).colorScheme.primary;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: ShapeDecoration(
          color: color.withValues(alpha: 0.14),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(size * 0.3),
          ),
        ),
        child: Icon(
          deviceIconFor(deviceName, typeValue),
          size: size * 0.55,
          color: color,
        ),
      ),
    );
  }
}
