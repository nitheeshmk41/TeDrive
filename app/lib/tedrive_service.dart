import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'device.dart' as device;
import 'picker_catalogue.dart';
import 'stored_file.dart';
import 'td/td_client.dart';
import 'thumbnailer.dart';

typedef Progress = void Function(int done, int total);

/// Thrown when the user cancels an upload that was in progress.
class UploadCancelled implements Exception {
  @override
  String toString() => 'Upload cancelled';
}

/// SHA-256 of a file, streamed off the UI isolate so large files are fine.
Future<String> sha256OfFile(String path) => Isolate.run(() async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
});

/// Everything TeDrive asks of Telegram: sign-in, the storage channel,
/// uploads, the catalogue and downloads.
class TeDriveService {
  final TdClient td = TdClient();

  /// Short auth state name: starting, needCredentials, waitPhoneNumber,
  /// waitCode, waitPassword, ready, loggingOut, closing, error, or another
  /// TDLib state.
  final ValueNotifier<String> authState = ValueNotifier('starting');
  String? lastError;

  /// Where the login code was sent, e.g. "your Telegram app" or "SMS".
  String? codeDestination;

  /// The hint the user set for their two-step verification password.
  String? passwordHint;

  static const _storage = FlutterSecureStorage();
  static const _apiIdKey = 'telegram_api_id';
  static const _apiHashKey = 'telegram_api_hash';

  String _dbDir = '';
  String _filesDir = '';
  String _dbKey = '';

  /// Name of this device, recorded with each upload.
  String deviceName = 'Unknown device';

  // Each user's own Telegram API credentials, entered in the app and kept
  // in Android Keystore-backed storage. Nothing is compiled into the app.
  int? _apiId;
  String? _apiHash;
  bool _clientOpen = false;

  /// True in the web demo, which shows sample files and has no account.
  bool get isDemo => td.isDemo;
  bool get hasCredentials => _apiId != null && _apiHash != null;

  Future<void> start() async {
    td.updates.listen(_onUpdate);
    await td.start();
    if (isDemo) {
      deviceName = 'Web demo';
      _apiId = 1;
      _apiHash = 'demo';
    } else {
      final support = await getApplicationSupportDirectory();
      _dbDir = '${support.path}/tdlib';
      _filesDir = '${support.path}/tdlib_files';
      _dbKey = await _loadOrCreateDbKey();
      _apiId = int.tryParse(await _storage.read(key: _apiIdKey) ?? '');
      _apiHash = await _storage.read(key: _apiHashKey);
      deviceName = await device.deviceName();
    }
    _openOrAskForCredentials();
  }

  void _openOrAskForCredentials() {
    if (hasCredentials) {
      authState.value = 'starting';
      _clientOpen = true;
      td.open();
    } else {
      authState.value = 'needCredentials';
    }
  }

  /// Saves the user's API credentials and (re)connects with them.
  Future<void> saveCredentials(int apiId, String apiHash) async {
    await _storage.write(key: _apiIdKey, value: '$apiId');
    await _storage.write(key: _apiHashKey, value: apiHash);
    _apiId = apiId;
    _apiHash = apiHash;
    await _restartClient();
  }

  /// Forgets the API credentials, returning to the setup screen.
  Future<void> clearCredentials() async {
    await _storage.delete(key: _apiIdKey);
    await _storage.delete(key: _apiHashKey);
    _apiId = null;
    _apiHash = null;
    await _restartClient();
  }

  /// Closes the current client if there is one. The `closed` update then
  /// opens a new client, or shows the setup screen.
  Future<void> _restartClient() async {
    if (_clientOpen) {
      authState.value = 'closing';
      await td.request({'@type': 'close'});
    } else {
      _openOrAskForCredentials();
    }
  }

  /// The TDLib database holds the Telegram session, so it is encrypted with
  /// a random key kept in Android Keystore.
  Future<String> _loadOrCreateDbKey() async {
    const name = 'tdlib_db_key';
    final existing = await _storage.read(key: name);
    if (existing != null) return existing;
    final rng = Random.secure();
    final key = base64Encode(List<int>.generate(32, (_) => rng.nextInt(256)));
    await _storage.write(key: name, value: key);
    return key;
  }

  void _onUpdate(Json update) {
    if (update['@type'] != 'updateAuthorizationState') return;
    final auth = update['authorization_state'] as Json;
    final name = (auth['@type'] as String).replaceFirst(
      'authorizationState',
      '',
    );
    final state = name[0].toLowerCase() + name.substring(1);
    switch (state) {
      case 'waitTdlibParameters':
        _sendParameters();
      case 'closed':
        // After logout or a credentials change: start again cleanly.
        _clientOpen = false;
        if (isDemo) {
          authState.value = 'starting';
          td.open();
        } else {
          _openOrAskForCredentials();
        }
      case 'waitCode':
        codeDestination = _describeCodeType(
          ((auth['code_info'] as Json?)?['type'] as Json?)?['@type'] as String?,
        );
        authState.value = state;
      case 'waitPassword':
        final hint = auth['password_hint'] as String?;
        passwordHint = hint == null || hint.isEmpty ? null : hint;
        authState.value = state;
      default:
        authState.value = state;
    }
  }

  static String? _describeCodeType(String? type) => switch (type) {
    'authenticationCodeTypeTelegramMessage' => 'a message in your Telegram app',
    'authenticationCodeTypeSms' => 'an SMS',
    'authenticationCodeTypeCall' => 'a phone call',
    'authenticationCodeTypeFlashCall' ||
    'authenticationCodeTypeMissedCall' => 'a missed call',
    _ => null,
  };

  Future<void> _sendParameters() async {
    try {
      await td.request({
        '@type': 'setTdlibParameters',
        'use_test_dc': false,
        'database_directory': _dbDir,
        'files_directory': _filesDir,
        'database_encryption_key': _dbKey,
        'use_file_database': true,
        'use_chat_info_database': true,
        'use_message_database': true,
        'use_secret_chats': false,
        'api_id': _apiId,
        'api_hash': _apiHash,
        'system_language_code': 'en',
        // Shown in Telegram's "Devices" list, so each device is recognisable.
        'device_model': 'TeDrive on $deviceName',
        'system_version': isDemo ? '' : Platform.operatingSystemVersion,
        'application_version': '1.0.0',
        'enable_storage_optimizer': false,
        'ignore_file_names': false,
      });
    } on TdError catch (e) {
      lastError = e.toString();
      authState.value = 'error';
    }
  }

  // ---- Login ----

  Future<void> setPhoneNumber(String phone) => td.request({
    '@type': 'setAuthenticationPhoneNumber',
    'phone_number': phone,
  });

  Future<void> checkCode(String code) =>
      td.request({'@type': 'checkAuthenticationCode', 'code': code});

  Future<void> checkPassword(String password) => td.request({
    '@type': 'checkAuthenticationPassword',
    'password': password,
  });

  Future<void> logOut() async {
    if (!isDemo) {
      await clearPickerCatalogue();
      await _storage.delete(key: 'setting_channel_id');
    }
    await td.request({'@type': 'logOut'});
  }

  // ---- Storage channel ----

  bool _isStorageChannel(Json chat) {
    final type = chat['type'] as Json;
    return chat['title'] == storageChannelTitle &&
        type['@type'] == 'chatTypeSupergroup' &&
        type['is_channel'] == true;
  }

  Future<List<int>> _matchingChannels(String method) async {
    final found = await td.request({
      '@type': method,
      'query': storageChannelTitle,
      'limit': 50,
    });
    final ids = <int>[];
    for (final id in (found['chat_ids'] as List).cast<int>()) {
      final chat = await td.request({'@type': 'getChat', 'chat_id': id});
      if (_isStorageChannel(chat)) ids.add(id);
    }
    return ids;
  }

  /// Loads the account's whole chat list, so a local search sees every chat.
  Future<void> _loadAllChats() async {
    for (var page = 0; page < 100; page++) {
      try {
        await td.request({
          '@type': 'loadChats',
          'chat_list': {'@type': 'chatListMain'},
          'limit': 100,
        });
      } on TdError {
        return; // 404: everything is loaded.
      }
    }
  }

  /// Finds this account's storage channel. Every device signed in to the
  /// same account must end up in the same channel, so the search is
  /// thorough before anything new is created: Telegram's server search,
  /// then the full chat list. If there are several channels with the right
  /// title, the oldest wins on every device.
  Future<int?> findChannel() async {
    final saved = int.tryParse(await readSetting('channel_id') ?? '');
    var ids = {
      ...await _matchingChannels('searchChatsOnServer'),
      ...await _matchingChannels('searchChats'),
    };
    if (ids.isEmpty) {
      await _loadAllChats();
      ids = {...await _matchingChannels('searchChats')};
    }
    if (ids.isEmpty && saved != null) {
      try {
        final chat = await td.request({'@type': 'getChat', 'chat_id': saved});
        if (_isStorageChannel(chat)) ids = {saved};
      } on TdError {
        // The saved channel no longer exists.
      }
    }
    if (ids.isEmpty) return null;
    // Channel ids only grow, so the smallest magnitude is the oldest.
    return ids.reduce((a, b) => a.abs() <= b.abs() ? a : b);
  }

  Future<int> createChannel() async {
    final chat = await td.request({
      '@type': 'createNewSupergroupChat',
      'title': storageChannelTitle,
      'is_forum': false,
      'is_channel': true,
      'description': 'TeDrive file storage. Do not delete messages here.',
      'message_auto_delete_time': 0,
      'for_import': false,
    });
    return chat['id'] as int;
  }

  Future<int> ensureChannel() async {
    final id = await findChannel() ?? await createChannel();
    if (!isDemo) await writeSetting('channel_id', '$id');
    return id;
  }

  Future<bool> isPremium() async {
    final me = await td.request({'@type': 'getMe'});
    return me['is_premium'] == true;
  }

  // ---- Upload ----

  /// Sends [path] as a document with its hash in the caption and waits
  /// until Telegram confirms it. [onStarted] receives the id needed by
  /// [cancelUpload].
  Future<StoredFile> upload(
    int chatId,
    String path,
    String sha, {
    String? folder,
    DateTime? taken,
    Thumbnail? thumbnail,
    Progress? onProgress,
    void Function(int tempMessageId)? onStarted,
  }) async {
    int? tempMessageId;
    int? fileId;
    final done = Completer<Json>();
    final sub = td.updates.listen((u) {
      switch (u['@type']) {
        case 'updateFile':
          final file = u['file'] as Json;
          if (file['id'] == fileId) {
            final remote = file['remote'] as Json;
            onProgress?.call(remote['uploaded_size'] as int, fileSize(file));
          }
        case 'updateMessageSendSucceeded':
          if (u['old_message_id'] == tempMessageId && !done.isCompleted) {
            done.complete(u['message'] as Json);
          }
        case 'updateMessageSendFailed':
          if (u['old_message_id'] == tempMessageId && !done.isCompleted) {
            final error = u['error'] as Json?;
            done.completeError(
              TdError(
                (error?['code'] ?? u['error_code'] ?? 0) as int,
                (error?['message'] ?? u['error_message'] ?? 'send failed')
                    as String,
              ),
            );
          }
        case 'updateDeleteMessages':
          if (u['chat_id'] == chatId &&
              u['is_permanent'] == true &&
              (u['message_ids'] as List).contains(tempMessageId) &&
              !done.isCompleted) {
            done.completeError(UploadCancelled());
          }
      }
    });
    try {
      final pending = await td.request({
        '@type': 'sendMessage',
        'chat_id': chatId,
        'input_message_content': {
          '@type': 'inputMessageDocument',
          'document': {'@type': 'inputFileLocal', 'path': path},
          // Keep the bytes untouched: no conversion to video or photo.
          'disable_content_type_detection': true,
          'caption': {
            '@type': 'formattedText',
            'text': buildCaption(
              sha256: sha,
              folder: folder,
              taken: taken,
              device: deviceName,
            ),
          },
          // Telegram makes no preview for videos sent as plain files, so
          // TeDrive supplies its own for the gallery.
          if (thumbnail != null)
            'thumbnail': {
              '@type': 'inputThumbnail',
              'thumbnail': {'@type': 'inputFileLocal', 'path': thumbnail.path},
              'width': thumbnail.width,
              'height': thumbnail.height,
            },
        },
      });
      tempMessageId = pending['id'] as int;
      fileId = StoredFile.fromMessage(pending)?.fileId;
      onStarted?.call(tempMessageId);
      final sent = await done.future;
      return StoredFile.fromMessage(sent)!;
    } finally {
      await sub.cancel();
    }
  }

  /// Stops an upload in progress by deleting its unsent message.
  Future<void> cancelUpload(int chatId, int tempMessageId) =>
      deleteFromDrive(chatId, [tempMessageId]);

  // ---- Catalogue from channel history ----

  /// Reads the channel history from Telegram, newest first. [onPage] gets
  /// the list so far after every page, so the UI can fill in gradually.
  Future<List<StoredFile>> history(
    int chatId, {
    int max = 20000,
    void Function(List<StoredFile> soFar)? onPage,
  }) async {
    final files = <StoredFile>[];
    var fromId = 0;
    while (files.length < max) {
      final page = await td.request({
        '@type': 'getChatHistory',
        'chat_id': chatId,
        'from_message_id': fromId,
        'offset': 0,
        'limit': 100,
        'only_local': false,
      });
      final messages = (page['messages'] as List).cast<Json>();
      if (messages.isEmpty) break;
      for (final m in messages) {
        final file = fileOf(m);
        if (file != null) files.add(file);
      }
      fromId = messages.last['id'] as int;
      onPage?.call(List.unmodifiable(files));
    }
    return files;
  }

  /// The file a message carries, if it is a finished (not still sending)
  /// message with one. Local paths that no longer exist are dropped.
  StoredFile? fileOf(Json message) {
    if (message['sending_state'] != null) return null;
    final file = StoredFile.fromMessage(message);
    if (file == null) return null;
    final path = file.localPath;
    return path != null && !isDemo && !File(path).existsSync()
        ? file.withLocalPath(null)
        : file;
  }

  /// Fetches one message again, e.g. after another device edited it.
  Future<StoredFile?> fetchFile(int chatId, int messageId) async {
    try {
      final message = await td.request({
        '@type': 'getMessage',
        'chat_id': chatId,
        'message_id': messageId,
      });
      return fileOf(message);
    } on TdError {
      return null;
    }
  }

  /// Permanently deletes messages (and their files) from the channel.
  Future<void> deleteFromDrive(int chatId, List<int> messageIds) => td.request({
    '@type': 'deleteMessages',
    'chat_id': chatId,
    'message_ids': messageIds,
    'revoke': true,
  });

  /// Moves a file to [folder] (null for none) by rewriting its caption.
  Future<void> setFolder(int chatId, StoredFile file, String? folder) =>
      td.request({
        '@type': 'editMessageCaption',
        'chat_id': chatId,
        'message_id': file.messageId,
        'caption': {
          '@type': 'formattedText',
          'text': file.withFolder(folder).caption,
        },
      });

  // ---- Settings ----

  Future<String?> readSetting(String name) =>
      _storage.read(key: 'setting_$name');

  Future<void> writeSetting(String name, String value) =>
      _storage.write(key: 'setting_$name', value: value);

  // ---- Download ----

  /// Local path of a file's small preview image, or null if it has none
  /// or it cannot be fetched right now.
  Future<String?> thumbnailPath(int thumbFileId) async {
    try {
      return await download(thumbFileId);
    } catch (_) {
      return null;
    }
  }

  /// Returns the local path of the file, downloading it from Telegram
  /// first if there is no complete copy on this phone.
  Future<String> download(int fileId, {Progress? onProgress}) async {
    var file = await td.request({'@type': 'getFile', 'file_id': fileId});
    final existing = _completePath(file);
    if (existing != null) return existing;
    if ((file['local'] as Json)['is_downloading_completed'] == true) {
      // TDLib remembers a copy that is gone. Make it forget, then download.
      await _deleteFile(fileId);
    }
    final sub = td.updates.listen((u) {
      if (u['@type'] != 'updateFile') return;
      final f = u['file'] as Json;
      if (f['id'] == fileId) {
        onProgress?.call(
          (f['local'] as Json)['downloaded_size'] as int,
          fileSize(f),
        );
      }
    });
    try {
      file = await td.request({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': 1,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      });
    } finally {
      await sub.cancel();
    }
    final path = _completePath(file);
    if (path == null) throw StateError('The download did not complete.');
    return path;
  }

  /// Reads [count] bytes of a file starting at [offset], downloading just
  /// that part from Telegram if it is not on the phone yet. This is what
  /// lets videos and audio play without a full download.
  Future<Uint8List> readPart(int fileId, int offset, int count) async {
    await td.request({
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': 32,
      'offset': offset,
      'limit': count,
      'synchronous': true,
    });
    final part = await td.request({
      '@type': 'readFilePart',
      'file_id': fileId,
      'offset': offset,
      'count': count,
    });
    return base64Decode(part['data'] as String);
  }

  /// Path of the complete local copy of a file, if there is one.
  Future<String?> localPathOf(int fileId) async =>
      _completePath(await td.request({'@type': 'getFile', 'file_id': fileId}));

  Future<void> cancelDownload(int fileId) => td.request({
    '@type': 'cancelDownloadFile',
    'file_id': fileId,
    'only_if_pending': false,
  });

  /// True if [path] is inside TeDrive's own download cache, so removing it
  /// can never touch one of the user's original files.
  bool isCached(String path) =>
      _filesDir.isNotEmpty && path.startsWith(_filesDir);

  /// Removes the downloaded copy of a file to free phone storage.
  /// Returns false if the file is not in TeDrive's cache.
  Future<bool> removeOfflineCopy(int fileId) async {
    final file = await td.request({'@type': 'getFile', 'file_id': fileId});
    final path = (file['local'] as Json)['path'] as String? ?? '';
    if (path.isEmpty || !isCached(path)) return false;
    await _deleteFile(fileId);
    return true;
  }

  Future<void> _deleteFile(int fileId) async {
    try {
      await td.request({'@type': 'deleteFile', 'file_id': fileId});
    } on TdError {
      // Nothing to delete.
    }
  }

  static String? _completePath(Json file) {
    final local = file['local'] as Json;
    final path = local['path'] as String? ?? '';
    return local['is_downloading_completed'] == true &&
            path.isNotEmpty &&
            File(path).existsSync()
        ? path
        : null;
  }
}
