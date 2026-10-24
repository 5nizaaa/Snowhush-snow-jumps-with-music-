# Snowhush

A tiny macOS menu bar app that lets soft snow fall over your desktop. It settles along the bottom of the screen and on the tops of your windows, slides off when you drag them and parts under your cursor.

[Download for macOS](https://github.com/mbezruchko/Snowhush/releases/latest/download/Snowhush.dmg) · macOS 14 or later

## Building

```sh
./build.sh            # build/Snowhush.app, signed ad hoc
open build/Snowhush.app
```

## Releasing

```sh
./release.sh 0.2.0 "What changed"
```

Bumps the version, signs with Developer ID, notarizes, and publishes `Snowhush.dmg` and `appcast.xml` as a GitHub release. The app checks the appcast of the latest release with Sparkle.

One-time setup on the release machine:

- a "Developer ID Application" certificate in the keychain;
- a notarytool profile: `xcrun notarytool store-credentials snowhush --apple-id <apple-id> --team-id <team-id>`;
- the Sparkle EdDSA private key in the login keychain (`.build/sparkle-tools/bin/generate_keys`); its public key is `SUPublicEDKey` in `Resources/Info.plist`.

## Site

`site/` is a static page served by Cloudflare Pages: no build command, output directory `site`.
