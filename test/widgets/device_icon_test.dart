import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/widgets/device_icon.dart';

void main() {
  group('describeDevice (A12)', () {
    test('Vaultwarden / Bitwarden display names', () {
      const cases = {
        'Chrome':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.chrome),
        'Edge': DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.edge),
        'Safari':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.safari),
        'Firefox':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.firefox),
        'Opera':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.opera),
        'Brave on macOS':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.brave),
        'Vivaldi':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.vivaldi),
        'Internet Explorer': DeviceDescriptor(DeviceKind.browser,
            brand: BrowserBrand.internetExplorer),
        'DuckDuckGo': DeviceDescriptor(DeviceKind.browser,
            brand: BrowserBrand.duckDuckGo),
        'Unknown Browser': DeviceDescriptor(DeviceKind.browser),
        'Firefox Extension':
            DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.firefox),
        'Chrome Extension':
            DeviceDescriptor(DeviceKind.extension, brand: BrowserBrand.chrome),
        'Windows': DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.windows),
        'macOS': DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.macos),
        'Linux': DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.linux),
        'UWP': DeviceDescriptor(DeviceKind.desktop, os: DesktopOs.windows),
        'Windows CLI': DeviceDescriptor(DeviceKind.cli, os: DesktopOs.windows),
        'MacOs CLI': DeviceDescriptor(DeviceKind.cli, os: DesktopOs.macos),
        'macOS CLI': DeviceDescriptor(DeviceKind.cli, os: DesktopOs.macos),
        'Linux CLI': DeviceDescriptor(DeviceKind.cli, os: DesktopOs.linux),
        'Android': DeviceDescriptor(DeviceKind.android),
        'iOS': DeviceDescriptor(DeviceKind.ios),
        'iPhone iOS': DeviceDescriptor(DeviceKind.ios),
        'Chrome on Android':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.chrome),
        'Safari on iPhone':
            DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.safari),
        'macOS Browser': DeviceDescriptor(DeviceKind.browser),
        'SDK': DeviceDescriptor(DeviceKind.server),
        'Server': DeviceDescriptor(DeviceKind.server),
        'Toaster': DeviceDescriptor(DeviceKind.unknown),
      };
      cases.forEach((name, expected) {
        expect(describeDevice(name), expected, reason: name);
      });
    });

    test('the numeric DeviceType (bitwarden.com) wins over the name', () {
      expect(describeDevice('Unknown', 12),
          const DeviceDescriptor(DeviceKind.browser, brand: BrowserBrand.edge));
      expect(
          describeDevice('Unknown', 17),
          const DeviceDescriptor(DeviceKind.browser,
              brand: BrowserBrand.safari));
      expect(describeDevice('Unknown', 25),
          const DeviceDescriptor(DeviceKind.cli, os: DesktopOs.linux));
      // Unknown values fall back to the name.
      expect(
          describeDevice('Firefox', 999),
          const DeviceDescriptor(DeviceKind.browser,
              brand: BrowserBrand.firefox));
    });

    test('icons', () {
      expect(deviceIconFor('Chrome'), Icons.language);
      expect(deviceIconFor('Firefox Extension'), Icons.extension_outlined);
      expect(deviceIconFor('Windows'), Icons.desktop_windows_outlined);
      expect(deviceIconFor('macOS'), Icons.laptop_mac);
      expect(deviceIconFor('Linux CLI'), Icons.terminal);
      expect(deviceIconFor('Android'), Icons.phone_android);
      expect(deviceIconFor('iOS'), Icons.phone_iphone);
      expect(deviceIconFor('Toaster'), Icons.devices);
    });

    test('browsers get their brand colour', () {
      expect(browserBrandColor(BrowserBrand.firefox), isNotNull);
      expect(browserBrandColor(null), isNull);
    });
  });
}
