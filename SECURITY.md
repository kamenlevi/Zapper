# Security Policy

## Supported versions

Zapper is built from source, so the supported version is always the current
`main`. Fixes land there; there are no backports.

## Reporting a vulnerability

Please report privately rather than opening a public issue: use
**Security → Report a vulnerability** on this repository
(GitHub private vulnerability reporting).

Include what you did, what happened, and the TV model and macOS version if
relevant. Expect a first reply within a week. If a report is valid, the fix
and a note in the release description follow as soon as it is ready; you are
credited unless you ask otherwise.

## What is in scope

- The webOS/SSAP client: WebSocket handshake, certificate pinning, and the
  pointer socket (`Sources/ZapperKit/WebOSSocket.swift`,
  `WebOSHandshake.swift`, `PointerSocket.swift`).
- Credential handling (`Sources/ZapperKit/CredentialStore.swift`,
  `Spotify.swift`), including the Spotify PKCE flow and its loopback
  redirect listener on `127.0.0.1:8917`.
- The screen-capture and OCR path (`ScreenText.swift`, `WebOSDevice.swift`),
  which fetches frames from the TV and reads them locally.
- Anything that lets a device other than your paired TV inject commands or
  read stored credentials.

Out of scope: vulnerabilities in webOS itself or in the TV apps Zapper
drives, and the third-party endpoints listed below. Report those upstream.

## How Zapper handles your data

- **Pairing material** (the TV's client key and pinned certificate
  fingerprint) is stored in
  `~/Library/Application Support/Zapper/devices.json`, mode `0600`. The
  Keychain is deliberately not used: a Keychain item binds to the code
  signature, so every local rebuild would trigger an authorization prompt.
  The key grants control of a TV on your local network and nothing else.
- **Spotify tokens** live beside it in `spotify.json`, mode `0600`. Zapper
  uses Authorization Code with PKCE and read-only playlist scopes, so no
  client secret is involved and Zapper never sees your password.
- **The TV's certificate is pinned** on first pair and required to match
  afterwards, so another device answering on that address cannot take over
  the session.
- **Screen captures** are fetched from the TV, processed in memory with
  Apple's Vision framework, and discarded. They are never written to disk or
  sent anywhere.
- **No telemetry, no analytics, no accounts.** Outbound network traffic is
  limited to: your TV on the local network; `apis.justwatch.com` and
  `images.justwatch.com` for title search and poster art; and
  `accounts.spotify.com` / `api.spotify.com` only if you connect Spotify.

## Notes for people building it

The app is signed ad-hoc with a stable bundle identifier, not with a
Developer ID, so macOS ties the Local Network permission to the bundle id
and the grant survives rebuilds. Review the source before you build it, as
you should with anything you compile off the internet.
