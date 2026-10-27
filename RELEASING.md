# Releasing

```sh
./release.sh 0.2.0 "What changed"
```

Bumps the version, signs with Developer ID, notarizes, and publishes `Snowhush.dmg` and `appcast.xml` as a GitHub release. The app checks the appcast of the latest release with Sparkle.

One-time setup on the release machine:

- a "Developer ID Application" certificate in the keychain;
- a notarytool profile: `xcrun notarytool store-credentials snowhush --apple-id <apple-id> --team-id <team-id>`;
- the Sparkle EdDSA private key in the login keychain (`.build/sparkle-tools/bin/generate_keys`); its public key is `SUPublicEDKey` in `Resources/Info.plist`.

## Site

`site/` is a static page served by Cloudflare Pages at [snowhush.pages.dev](https://snowhush.pages.dev): no build command, output directory `site`. Every push to `main` deploys it.
