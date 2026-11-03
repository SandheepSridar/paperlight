# Paperlight

A calm, Kindle-style reader for PDF and EPUB books, made for a Samsung Galaxy Tab.

- **Your books only.** Books are added with Android's file chooser and copied
  into the app's private storage. The app has no storage permission and never
  scans the tablet.
- **Easy reading.** Tap the right side to go to the next page and the left side
  to go back; tap the middle for the menu. Your place is saved automatically.
- **Text & display (Aa).** Text size, font, line spacing, margins (EPUB),
  White / Sepia / Night pages, and in-app brightness.
- **Light on battery.** Nothing runs in the background. Only visible pages are
  rendered, covers are made once at import, and the screen still sleeps as
  usual. The update check is one request a day.
- **Updates itself.** The app checks GitHub Releases; when there's a new
  version, tap **Update now**, then **Install**.

## Develop

```sh
flutter pub get
flutter test
flutter run --release            # with the Tab connected (USB or wireless adb)
```

## Releasing an update

1. Bump `version:` in `pubspec.yaml`, e.g. `1.0.0+1` → `1.0.1+2`. Always
   increase the `+build` number too, because Android uses it to decide what's
   newer.
2. Commit, then tag and push:
   ```sh
   git commit -am "Release 1.0.1"
   git tag v1.0.1 && git push && git push --tags
   ```
3. GitHub Actions runs the tests, builds a signed APK and publishes the release.
   The next time the app opens (or from Settings → Check for updates), the
   tablet offers the update.

## One-time setup

### Signing (critical)
`android/app/paperlight-release.jks` and `android/key.properties` are the app's
signing key. Both are gitignored. **Back them up somewhere safe**, such as a
password manager. If the key is lost, the Tab won't accept updates: you'd have
to uninstall the app, which also deletes the library.

### GitHub
The updater reads `https://api.github.com/repos/SandheepSridar/paperlight/releases/latest`.
The repo must be **public**, because a private repo would need a token inside
the app. To use another repo, build with `--dart-define=UPDATE_REPO=owner/name`
and pass the same flag in the workflow.

```sh
gh repo create paperlight --public --source=. --push
gh secret set ANDROID_KEYSTORE_BASE64 < <(base64 -i android/app/paperlight-release.jks)
gh secret set ANDROID_KEY_PROPERTIES < android/key.properties
```

### First install on the Tab
Install the first version yourself, for example from the GitHub release page
in the Tab's browser, or with `adb install`. When the first update arrives,
Android asks once to allow Paperlight to install apps: tap **Settings** and
turn on **Allow from this source**.

## Layout

```
lib/
  main.dart                 startup, app theme
  app/                      theme colours, reading preferences
  data/                     sqflite database, models, LibraryRepo
  import/                   file picker → private copy, EPUB metadata, covers
  ui/library_screen.dart    library grid + "Continue reading"
  ui/reader/                PDF reader (pdfrx), EPUB reader (epub.js), shared controls
  update/                   GitHub Releases check + APK install
```
