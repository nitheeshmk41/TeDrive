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
import 'local_files.dart';
import 'picker_catalogue.dart';
import 'stored_file.dart';
import 'td/td_client.dart';
import 'td/web_bridge.dart';
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

/// SHA-256 of a stream of bytes, e.g. a file picked in a browser.
Future<String> sha256OfStream(Stream<List<int>> bytes) async =>
    (await sha256.bind(bytes).first).toString();

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

  bool get hasCredentials => _apiId != null && _apiHash != null;

  Future<void> start() async {
    td.updates.listen(_onUpdate);
    await td.start();
    if (!kIsWeb) {
      // In the browser tdweb chooses its own storage (IndexedDB).
      final support = await getApplicationSupportDirectory();
      _dbDir = '${support.path}/tdlib';
      _filesDir = '${support.path}/tdlib_files';
      _dbKey = await _loadOrCreateDbKey();
    }
    _apiId = int.tryParse(await _storage.read(key: _apiIdKey) ?? '');
    _apiHash = await _storage.read(key: _apiHashKey);
    deviceName = await device.deviceName();
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
        _webUrls.clear();
        _openOrAskForCredentials();
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
        'system_version': kIsWeb ? '' : Platform.operatingSystemVersion,
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
    await clearPickerCatalogue();
    await _storage.delete(key: 'setting_channel_id');
    await td.request({'@type': 'logOut'});
  }

  // ---- Storage channel ----

  bool _isChannelTitled(Json chat, String title) {
    final type = chat['type'] as Json;
    return chat['title'] == title &&
        type['@type'] == 'chatTypeSupergroup' &&
        type['is_channel'] == true;
  }

  Future<List<int>> _matchingChannels(String method, String title) async {
    final found = await td.request({
      '@type': method,
      'query': title,
      'limit': 50,
    });
    final ids = <int>[];
    for (final id in (found['chat_ids'] as List).cast<int>()) {
      final chat = await td.request({'@type': 'getChat', 'chat_id': id});
      if (_isChannelTitled(chat, title)) ids.add(id);
    }
    return ids;
  }

  /// The oldest channel with [title] in this account, or null.
  Future<int?> _findChannelTitled(String title, {int? saved}) async {
    var ids = {
      ...await _matchingChannels('searchChatsOnServer', title),
      ...await _matchingChannels('searchChats', title),
    };
    if (ids.isEmpty) {
      await _loadAllChats();
      ids = {...await _matchingChannels('searchChats', title)};
    }
    if (ids.isEmpty && saved != null) {
      try {
        final chat = await td.request({'@type': 'getChat', 'chat_id': saved});
        if (_isChannelTitled(chat, title)) ids = {saved};
      } on TdError {
        // The saved channel no longer exists.
      }
    }
    if (ids.isEmpty) return null;
    // Channel ids only grow, so the smallest magnitude is the oldest.
    return ids.reduce((a, b) => a.abs() <= b.abs() ? a : b);
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
  Future<int?> findChannel() async => _findChannelTitled(
    storageChannelTitle,
    saved: int.tryParse(await readSetting('channel_id') ?? ''),
  );

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
    await writeSetting('channel_id', '$id');
    return id;
  }

  Future<bool> isPremium() async => (await me())['is_premium'] == true;

  /// The signed-in Telegram user.
  Future<Json> me() => td.request({'@type': 'getMe'});

  // ---- Upload ----

  /// Sends [path] as a document with its hash in the caption and waits
  /// until Telegram confirms it. [onStarted] receives the id needed by
  /// [cancelUpload].
  Future<StoredFile> upload(
    int chatId,
    Json inputFile,
    String sha, {
    String? folder,
    DateTime? taken,
    Thumbnail? thumbnail,
    Progress? onProgress,
    void Function(int tempMessageId)? onStarted,
  }) => _sendAndWait(
    chatId,
    {
      '@type': 'inputMessageDocument',
      'document': inputFile,
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
    onProgress: onProgress,
    onStarted: onStarted,
  ).then((sent) => StoredFile.fromMessage(sent)!);

  /// Sends a message and waits until Telegram has stored it. Completes
  /// with the sent message.
  Future<Json> _sendAndWait(
    int chatId,
    Json content, {
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
        'input_message_content': content,
      });
      tempMessageId = pending['id'] as int;
      fileId = StoredFile.fromMessage(pending)?.fileId;
      onStarted?.call(tempMessageId);
      return await done.future;
    } finally {
      await sub.cancel();
    }
  }

  // ---- Public share links ----

  /// Shared files are copied into this public channel. It is separate
  /// from the private storage channel, which stays private.
  static const shareChannelTitle = 'TeDrive Shared';

  /// The public sharing channel and its username, created on first use.
  Future<({int chatId, String username})> _ensureShareChannel() async {
    final saved = int.tryParse(await readSetting('share_channel_id') ?? '');
    var chatId = await _findChannelTitled(shareChannelTitle, saved: saved);
    if (chatId == null) {
      final chat = await td.request({
        '@type': 'createNewSupergroupChat',
        'title': shareChannelTitle,
        'is_forum': false,
        'is_channel': true,
        'description':
            'Files shared from TeDrive. Anyone with a link can see them.',
        'message_auto_delete_time': 0,
        'for_import': false,
      });
      chatId = chat['id'] as int;
    }
    await writeSetting('share_channel_id', '$chatId');
    final chat = await td.request({'@type': 'getChat', 'chat_id': chatId});
    final supergroupId = (chat['type'] as Json)['supergroup_id'] as int;
    var username = await _publicUsername(supergroupId);
    if (username == null) {
      // A public link needs a public username. Pick a random free one.
      final rng = Random.secure();
      for (var attempt = 0; attempt < 8 && username == null; attempt++) {
        final candidate = randomShareUsername(rng.nextInt);
        try {
          final check = await td.request({
            '@type': 'checkChatUsername',
            'chat_id': chatId,
            'username': candidate,
          });
          if (check['@type'] == 'checkChatUsernameResultPublicChatsTooMany') {
            break;
          }
          if (check['@type'] != 'checkChatUsernameResultOk') continue;
          await td.request({
            '@type': 'setSupergroupUsername',
            'supergroup_id': supergroupId,
            'username': candidate,
          });
          username = candidate;
        } catch (_) {}
      }
      if (username == null) {
        throw StateError(
          'Could not set a public link name on Telegram. '
          'Please ensure your Telegram account allows creating public channels.',
        );
      }
    }
    return (chatId: chatId, username: username);
  }

  Future<String?> _publicUsername(int supergroupId) async {
    final sg = await td.request({
      '@type': 'getSupergroup',
      'supergroup_id': supergroupId,
    });
    final active = ((sg['usernames'] as Json?)?['active_usernames'] as List?)
        ?.cast<String>();
    if (active != null && active.isNotEmpty) return active.first;
    final old = sg['username'] as String?;
    return old == null || old.isEmpty ? null : old;
  }

  /// Makes a public link for [file] and records it in the file's caption.
  /// Uses instant server-side copy via Telegram (zero network bandwidth),
  /// falling back to a direct media upload if needed.
  Future<String> createShareLink(
    int storageChatId,
    StoredFile file, {
    String? localCopy,
    Progress? onProgress,
  }) async {
    final share = await _ensureShareChannel();
    int? blobId;
    try {
      int? postId;

      // 1. Instant server-side message copy via Telegram (fast, 0 download/upload)
      try {
        final forwarded = await td.request({
          '@type': 'forwardMessages',
          'chat_id': share.chatId,
          'from_chat_id': storageChatId,
          'message_ids': [file.messageId],
          'send_copy': true,
          'remove_caption': false,
        });
        final messages = (forwarded['messages'] as List?)?.cast<Json?>();
        final first = messages?.firstWhere((m) => m != null, orElse: () => null);
        if (first != null) {
          postId = (first['id'] as int) >> 20;
          try {
            await td.request({
              '@type': 'editMessageCaption',
              'chat_id': share.chatId,
              'message_id': first['id'] as int,
              'caption': {'@type': 'formattedText', 'text': file.name},
            });
          } catch (_) {}
        }
      } catch (_) {
        // Fall back to direct media send below
      }

      // 2. Fallback: direct media message send
      if (postId == null) {
        Json? input;
        if (localCopy != null) {
          if (kIsWeb) {
            blobId = await WebTd.putBlob(localCopy);
            input = {
              '@type': 'inputFileBlob',
              'name': file.name,
              'blob_id': blobId,
            };
          } else {
            input = {'@type': 'inputFileLocal', 'path': localCopy};
          }
        }
        final caption = {'@type': 'formattedText', 'text': file.name};
        final Json content = switch (file.kind) {
          FileKind.image when input != null => {
            '@type': 'inputMessagePhoto',
            'photo': input,
            'caption': caption,
          },
          FileKind.video when input != null => {
            '@type': 'inputMessageVideo',
            'video': input,
            'supports_streaming': true,
            'caption': caption,
          },
          _ => {
            '@type': 'inputMessageDocument',
            'document': await _remoteInputFile(file),
            'caption': caption,
          },
        };
        final sent = await _sendAndWait(
          share.chatId,
          content,
          onProgress: onProgress,
        );
        postId = (sent['id'] as int) >> 20;
      }

      final link = 'https://t.me/${share.username}/$postId';
      await _setCaption(
        storageChatId,
        file.messageId,
        file.withShareLink(link).caption,
      );
      return link;
    } finally {
      if (blobId != null) WebTd.releaseBlob(blobId);
    }
  }

  /// The file already in Telegram, so it can be sent again without upload.
  Future<Json> _remoteInputFile(StoredFile file) async {
    final f = await td.request({'@type': 'getFile', 'file_id': file.fileId});
    final remoteId = (f['remote'] as Json?)?['id'] as String? ?? '';
    if (remoteId.isEmpty) throw StateError('That file is not in Telegram yet.');
    return {'@type': 'inputFileRemote', 'id': remoteId};
  }

  /// Deletes the public copy and removes the link from the caption.
  Future<void> removeShareLink(int storageChatId, StoredFile file) async {
    final link = parseShareLink(file.shareLink);
    if (link != null) {
      try {
        final share = await _ensureShareChannel();
        if (share.username.toLowerCase() == link.username.toLowerCase()) {
          await deleteFromDrive(share.chatId, [link.post << 20]);
        }
      } catch (_) {
        // Already gone. The caption is cleaned up below either way.
      }
    }
    await _setCaption(
      storageChatId,
      file.messageId,
      file.withShareLink(null).caption,
    );
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
    // In the browser TDLib's paths are internal; a usable copy is a blob:
    // URL, made when the file is opened.
    if (kIsWeb) return file.withLocalPath(_webUrls[file.fileId]);
    return localExists(file.localPath) ? file : file.withLocalPath(null);
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
      _setCaption(chatId, file.messageId, file.withFolder(folder).caption);

  /// Gives a file a new display name by rewriting its caption. The name
  /// then shows on every device.
  Future<void> rename(int chatId, StoredFile file, String newName) =>
      _setCaption(chatId, file.messageId, file.renamed(newName).caption);

  Future<void> _setCaption(int chatId, int messageId, String caption) =>
      td.request({
        '@type': 'editMessageCaption',
        'chat_id': chatId,
        'message_id': messageId,
        'caption': {'@type': 'formattedText', 'text': caption},
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

  /// blob: URLs of files downloaded in the browser, by file id.
  final Map<int, String> _webUrls = {};

  /// Returns the local path of the file, downloading it from Telegram
  /// first if there is no complete copy on this phone. In the browser this
  /// is a blob: URL.
  Future<String> download(
    int fileId, {
    Progress? onProgress,
    String? mime,
  }) async {
    if (kIsWeb) return _webDownload(fileId, onProgress: onProgress, mime: mime);
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

  Future<String> _webDownload(
    int fileId, {
    Progress? onProgress,
    String? mime,
  }) async {
    final known = _webUrls[fileId];
    if (known != null) return known;
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
      await td.request({
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
    final url = await WebTd.fileUrl(fileId, mime: mime);
    if (url == null) throw StateError('The download did not complete.');
    return _webUrls[fileId] = url;
  }

  /// Uploads a file picked in the browser (given by its blob: URL).
  Future<StoredFile> uploadBlob(
    int chatId,
    String blobUrl,
    String name,
    String sha, {
    String? folder,
    Progress? onProgress,
    void Function(int tempMessageId)? onStarted,
  }) async {
    final blobId = await WebTd.putBlob(blobUrl);
    try {
      return await upload(
        chatId,
        {'@type': 'inputFileBlob', 'name': name, 'blob_id': blobId},
        sha,
        folder: folder,
        onProgress: onProgress,
        onStarted: onStarted,
      );
    } finally {
      WebTd.releaseBlob(blobId);
    }
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
  Future<String?> localPathOf(int fileId) async => kIsWeb
      ? _webUrls[fileId]
      : _completePath(
          await td.request({'@type': 'getFile', 'file_id': fileId}),
        );

  Future<void> cancelDownload(int fileId) => td.request({
    '@type': 'cancelDownloadFile',
    'file_id': fileId,
    'only_if_pending': false,
  });

  /// Bytes used by copies TeDrive has downloaded to this device, or null
  /// where that cannot be measured (in a browser).
  Future<int?> cacheBytes() async {
    if (kIsWeb) return null;
    final stats = await td.request({'@type': 'getStorageStatisticsFast'});
    return stats['files_size'] as int? ?? 0;
  }

  /// Deletes downloaded copies, least recently used first, until at most
  /// [maxBytes] remain. Only TeDrive's own cache is touched, and files
  /// opened in the last hour are left alone. Everything stays in Telegram.
  Future<void> trimCache(int maxBytes) async {
    if (kIsWeb) return; // The browser manages its own storage.
    await td.request({
      '@type': 'optimizeStorage',
      'size': maxBytes,
      'ttl': -1,
      'count': -1,
      'immunity_delay': maxBytes == 0 ? 0 : 3600,
      'file_types': const <Object>[],
      'chat_ids': const <int>[],
      'exclude_chat_ids': const <int>[],
      'return_deleted_file_statistics': false,
      'chat_limit': 0,
    });
  }

  /// True if [path] is inside TeDrive's own download cache, so removing it
  /// can never touch one of the user's original files.
  bool isCached(String path) => kIsWeb
      ? path.startsWith('blob:')
      : _filesDir.isNotEmpty && path.startsWith(_filesDir);

  /// Removes the downloaded copy of a file to free phone storage.
  /// Returns false if the file is not in TeDrive's cache.
  Future<bool> removeOfflineCopy(int fileId) async {
    if (kIsWeb) {
      if (_webUrls.remove(fileId) == null) return false;
      await _deleteFile(fileId);
      return true;
    }
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
