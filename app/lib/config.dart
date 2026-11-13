/// Title of the private channel that holds the files.
const String storageChannelTitle = 'TeDrive Storage';

/// True in the Google Play build, which Google Play updates itself.
const bool isPlayBuild = String.fromEnvironment('STORE') == 'play';

/// This build's version. Keep in step with `version:` in pubspec.yaml
/// (a unit test checks this).
const String appVersion = '3.2.1';
