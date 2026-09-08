# JellyBlair

JellyBlair is a native audiobook client for [Jellyfin](https://jellyfin.org), for macOS and iOS. It is built with SwiftUI and AVFoundation. It plays audiobooks from your Jellyfin server, shows chapters and a word-synced transcript from lyric sidecars, downloads books for offline listening, and reports playback progress back to the server.

## Requirements

- A Jellyfin server with audiobook libraries.
- macOS 15 or iOS 18.
- Xcode 16 or newer, and [xcodegen](https://github.com/yonaskolb/XcodeGen).

Neither is needed to work on `JellyBlairKit`, which holds nearly all of the code. `swift build` compiles it with the command line tools alone.

## Build

Every target takes a `PLATFORM` of `mac` or `ios`, and defaults to `mac`.

```sh
make build                  # build the Mac app
make run                    # build it, then launch it
make install                # build it, then copy it into /Applications
make build PLATFORM=ios     # build the iOS app
make run PLATFORM=ios       # build it, install it on DEVICE, then launch it
make clean
```

The Xcode project is generated from `Apps/project.yml`, which describes both apps. You can also run `cd Apps && xcodegen generate` and work in Xcode.

Code signing is optional. Without a team the apps still build and run locally, signed ad hoc. To sign them, create an untracked `Makefile.local` in the repository root:

```make
TEAM_ID        := <your Apple team ID>
DEVICE         := <your device name>
NOTARY_PROFILE := <your notarytool keychain profile>
```

## Distribution

`archive` builds a distribution archive, and `export` ships it to a channel. Both need `TEAM_ID`.

```sh
make archive                                    # archive the Mac app
make export METHOD=app-store-connect            # export it for the App Store
make export METHOD=developer-id                 # export, notarize, and staple it

make archive PLATFORM=ios
make export PLATFORM=ios METHOD=app-store-connect
```

`developer-id` applies to the Mac only, and it needs `NOTARY_PROFILE`, which you create once with `xcrun notarytool store-credentials`. Everything lands in `dist`.

## Versioning

The app version lives in the `VERSION` file. The make targets stamp it into both platforms' bundles, and the client reports it to the server. The build number is the repository's commit count. The make targets stamp it in the same way.

## License

MIT. See [LICENSE](LICENSE).
