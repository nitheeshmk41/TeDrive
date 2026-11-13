# Contributing to TeDrive

Thanks for helping. Bug reports, fixes and small features are all welcome.

## Reporting a bug

Open an issue with:

- the platform and TeDrive version (**Account → About**),
- what you did, what you expected and what happened,
- a screenshot if it is visual.

Never paste your Telegram API hash, login codes or session files.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Set up Flutter as described in [docs/building.md](docs/building.md).
3. Make the change. Keep it focused: one fix or feature per pull request.
4. Run the checks:

   ```bash
   cd app
   flutter analyze
   dart test
   ```

5. Add a line under a new heading at the top of `CHANGELOG.md` if users will notice the change.
6. Open a pull request that says what changed and how you tested it. Mention which platforms you tried.

## Ground rules

- **No server.** TeDrive works with nothing but the user's Telegram account. Features that need a backend are out of scope.
- **Metadata lives in captions.** New per-file data is a new `key:value` caption line, parsed in `app/lib/stored_file.dart` with a unit test.
- **Never delete the user's files by surprise.** Anything that removes data from the phone or Telegram asks first.
- **Pure-Dart logic gets a unit test** in `app/test/`.
- Match the existing style: `dart format`, plain user-facing wording.

## License

By contributing you agree that your work is released under the [MIT License](LICENSE).
