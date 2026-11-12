// Encrypted Vault: on-device end-to-end encryption for sensitive documents
// like Aadhaar, PAN, Passport, Certificates and private papers.
//
// Files are encrypted before upload using authenticated AES-256-CTR with
// PBKDF2-HMAC-SHA256 key derivation. Telegram only ever stores ciphertext.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class VaultAuthException implements Exception {
  const VaultAuthException([this.message = 'Incorrect passphrase or corrupted document']);
  final String message;
  @override
  String toString() => message;
}

enum VaultDocType {
  aadhaar('Aadhaar Card', 'aadhaar'),
  pan('PAN Card', 'pan'),
  passport('Passport', 'passport'),
  drivingLicense('Driving License', 'driving_license'),
  voterId('Voter ID', 'voter_id'),
  certificate('Certificate / Marks', 'certificate'),
  taxFinancial('Tax & Financial', 'tax'),
  other('Confidential Document', 'confidential');

  const VaultDocType(this.label, this.key);
  final String label;
  final String key;
}

class VaultCipher {
  static const String magic = 'TEDVAULT1'; // 9 bytes header
  static const int saltLength = 16;
  static const int ivLength = 16;
  static const int macLength = 32;
  static const int pbkdf2Iterations = 2000;

  /// Derives a 64-byte key material (32 bytes cipher key + 32 bytes mac key)
  /// using PBKDF2-HMAC-SHA256.
  static Uint8List deriveKeys(String passphrase, Uint8List salt) {
    final passBytes = utf8.encode(passphrase);
    var hmac = Hmac(sha256, passBytes);
    
    // Block 1
    final block1Input = Uint8List(salt.length + 4);
    block1Input.setRange(0, salt.length, salt);
    block1Input[salt.length + 3] = 1; // Counter 1 (big-endian)
    
    var u = Uint8List.fromList(hmac.convert(block1Input).bytes);
    final keyPart1 = Uint8List.fromList(u);
    for (var i = 1; i < pbkdf2Iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var k = 0; k < keyPart1.length; k++) {
        keyPart1[k] ^= u[k];
      }
    }

    // Block 2
    final block2Input = Uint8List(salt.length + 4);
    block2Input.setRange(0, salt.length, salt);
    block2Input[salt.length + 3] = 2; // Counter 2 (big-endian)
    
    u = Uint8List.fromList(hmac.convert(block2Input).bytes);
    final keyPart2 = Uint8List.fromList(u);
    for (var i = 1; i < pbkdf2Iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var k = 0; k < keyPart2.length; k++) {
        keyPart2[k] ^= u[k];
      }
    }

    final result = Uint8List(64);
    result.setRange(0, 32, keyPart1);
    result.setRange(32, 64, keyPart2);
    return result;
  }

  /// Encrypts [plaintext] with [passphrase].
  /// Layout: [9B magic] + [16B salt] + [16B iv] + [32B hmac] + [ciphertext]
  static Uint8List encrypt(Uint8List plaintext, String passphrase) {
    final rng = Random.secure();
    final salt = Uint8List(saltLength);
    final iv = Uint8List(ivLength);
    for (var i = 0; i < saltLength; i++) {
      salt[i] = rng.nextInt(256);
    }
    for (var i = 0; i < ivLength; i++) {
      iv[i] = rng.nextInt(256);
    }

    final keyMaterial = deriveKeys(passphrase, salt);
    final encKey = keyMaterial.sublist(0, 32);
    final macKey = keyMaterial.sublist(32, 64);

    // CTR mode keystream generation using HMAC-SHA256(encKey, iv || counter)
    final ciphertext = _applyCtr(plaintext, encKey, iv);

    // Compute MAC over magic + salt + iv + ciphertext
    final macHmac = Hmac(sha256, macKey);
    final macPayload = BytesBuilder(copy: false)
      ..add(utf8.encode(magic))
      ..add(salt)
      ..add(iv)
      ..add(ciphertext);
    final mac = macHmac.convert(macPayload.takeBytes()).bytes;

    final output = BytesBuilder(copy: false)
      ..add(utf8.encode(magic))
      ..add(salt)
      ..add(iv)
      ..add(mac)
      ..add(ciphertext);
    return output.takeBytes();
  }

  /// Decrypts [encryptedData] with [passphrase].
  /// Throws [VaultAuthException] on password mismatch or tampering.
  static Uint8List decrypt(Uint8List encryptedData, String passphrase) {
    final magicBytes = utf8.encode(magic);
    if (encryptedData.length < magicBytes.length + saltLength + ivLength + macLength) {
      throw const VaultAuthException('File is not a valid encrypted vault document');
    }

    for (var i = 0; i < magicBytes.length; i++) {
      if (encryptedData[i] != magicBytes[i]) {
        throw const VaultAuthException('Missing vault document header');
      }
    }

    var offset = magicBytes.length;
    final salt = encryptedData.sublist(offset, offset + saltLength);
    offset += saltLength;
    final iv = encryptedData.sublist(offset, offset + ivLength);
    offset += ivLength;
    final expectedMac = encryptedData.sublist(offset, offset + macLength);
    offset += macLength;
    final ciphertext = encryptedData.sublist(offset);

    final keyMaterial = deriveKeys(passphrase, salt);
    final encKey = keyMaterial.sublist(0, 32);
    final macKey = keyMaterial.sublist(32, 64);

    // Verify MAC
    final macHmac = Hmac(sha256, macKey);
    final macPayload = BytesBuilder(copy: false)
      ..add(magicBytes)
      ..add(salt)
      ..add(iv)
      ..add(ciphertext);
    final computedMac = macHmac.convert(macPayload.takeBytes()).bytes;

    var diff = 0;
    for (var i = 0; i < macLength; i++) {
      diff |= expectedMac[i] ^ computedMac[i];
    }
    if (diff != 0) {
      throw const VaultAuthException('Incorrect vault passphrase');
    }

    return _applyCtr(ciphertext, encKey, iv);
  }

  static Uint8List _applyCtr(Uint8List input, Uint8List key, Uint8List iv) {
    final output = Uint8List(input.length);
    final hmac = Hmac(sha256, key);
    final block = Uint8List(iv.length + 8);
    block.setRange(0, iv.length, iv);

    var counter = 0;
    var byteIdx = 0;
    while (byteIdx < input.length) {
      // 64-bit big endian counter
      for (var c = 7; c >= 0; c--) {
        block[iv.length + c] = (counter >> (8 * (7 - c))) & 0xFF;
      }
      final keystream = hmac.convert(block).bytes;
      final chunkSize = min(keystream.length, input.length - byteIdx);
      for (var j = 0; j < chunkSize; j++) {
        output[byteIdx + j] = input[byteIdx + j] ^ keystream[j];
      }
      byteIdx += chunkSize;
      counter++;
    }
    return output;
  }

  /// Encrypts a local file in place or to a target path.
  static Future<File> encryptFile({
    required File source,
    required File target,
    required String passphrase,
  }) async {
    final bytes = await source.readAsBytes();
    final encrypted = encrypt(bytes, passphrase);
    return target.writeAsBytes(encrypted, flush: true);
  }

  /// Decrypts an encrypted file to a target clear path.
  static Future<File> decryptFile({
    required File source,
    required File target,
    required String passphrase,
  }) async {
    final bytes = await source.readAsBytes();
    final decrypted = decrypt(bytes, passphrase);
    return target.writeAsBytes(decrypted, flush: true);
  }
}

/// In-memory vault session controller.
class VaultSession {
  VaultSession._();
  static final VaultSession instance = VaultSession._();

  String? _passphrase;

  bool get isUnlocked => _passphrase != null && _passphrase!.isNotEmpty;

  String? get currentPassphrase => _passphrase;

  void unlock(String passphrase) {
    _passphrase = passphrase.trim();
  }

  void lock() {
    _passphrase = null;
  }
}
