/// Title of the private channel that holds the files.
const String storageChannelTitle = 'TeDrive Storage';

/// True in the Google Play build, which Google Play updates itself.
const bool isPlayBuild = String.fromEnvironment('STORE') == 'play';

/// This build's version. Keep in step with `version:` in pubspec.yaml
/// (a unit test checks this).
const String appVersion = '3.3.0';

/// Who made TeDrive, shown in About and at the foot of the Account page.
const String madeByText = 'This was done by Nitheesh.';
const String authorGithubUrl = 'https://github.com/nitheeshmk41';
const String repoGithubUrl = 'https://github.com/nitheeshmk41/TeDrive';
