import 'dart:convert';
import 'dart:typed_data';

import 'encryption_type.dart';

/// Parses and encodes Bitwarden CipherString format.
///
/// Symmetric type 0: "0.{base64_iv}|{base64_ct}"
/// Symmetric types 1, 2: "encType.{base64_iv}|{base64_ct}|{base64_mac}" — the
///   MAC is mandatory (as in the official SDK).
/// Asymmetric (type 3,4): "encType.{base64_ct}"; (5,6): "encType.{ct}|{mac}".
class CipherString {
  final EncryptionType encType;
  final Uint8List? iv;
  final Uint8List ciphertext;
  final Uint8List? mac;

  CipherString({
    required this.encType,
    this.iv,
    required this.ciphertext,
    this.mac,
  });

  /// Throws [FormatException] on anything malformed (unknown type, missing
  /// parts, missing MAC for MAC'd types, bad base64).
  factory CipherString.parse(String encoded) {
    final dotIndex = encoded.indexOf('.');
    if (dotIndex == -1) {
      throw const FormatException('Invalid CipherString: no type prefix');
    }

    final typeValue = int.tryParse(encoded.substring(0, dotIndex));
    if (typeValue == null) {
      throw const FormatException('Invalid CipherString: bad type prefix');
    }
    final encType = EncryptionType.fromValue(typeValue);
    final rest = encoded.substring(dotIndex + 1);
    final parts = rest.split('|');

    Uint8List b64(String s) {
      if (s.isEmpty) throw const FormatException('Invalid CipherString part');
      return base64Decode(s);
    }

    if (encType.hasIv) {
      final expected = encType.hasMac ? 3 : 2;
      if (parts.length != expected) {
        throw const FormatException('Invalid symmetric CipherString');
      }
      final iv = b64(parts[0]);
      if (iv.length != 16) {
        throw const FormatException('Invalid CipherString IV length');
      }
      return CipherString(
        encType: encType,
        iv: iv,
        ciphertext: b64(parts[1]),
        mac: encType.hasMac ? b64(parts[2]) : null,
      );
    }

    final expected = encType.hasMac ? 2 : 1;
    if (parts.length != expected) {
      throw const FormatException('Invalid asymmetric CipherString');
    }
    return CipherString(
      encType: encType,
      ciphertext: b64(parts[0]),
      mac: encType.hasMac ? b64(parts[1]) : null,
    );
  }

  String encode() {
    final buf = StringBuffer('${encType.value}.');
    if (encType.hasIv && iv != null) {
      buf.write(base64Encode(iv!));
      buf.write('|');
    }
    buf.write(base64Encode(ciphertext));
    if (encType.hasMac && mac != null) {
      buf.write('|');
      buf.write(base64Encode(mac!));
    }
    return buf.toString();
  }

  @override
  String toString() => encode();
}
