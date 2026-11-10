<p align="center"><img src="docs/icon.png" width="128" height="128" alt="Splyt icon"></p>

# Splyt

[![CI](https://github.com/trajche/splyt/actions/workflows/ci.yml/badge.svg)](https://github.com/trajche/splyt/actions/workflows/ci.yml)

Per-app routing for macOS: each app uses the VPN, goes direct, or is blocked. It runs
WireGuard tunnels itself, and also works with any other VPN that owns the default route.

## How it works

Keep the VPN on system-wide, then pull apps out of it. Splyt never touches the VPN or
the routing table. A transparent proxy system extension sees each new outbound flow:

| App's route | VPN active | No VPN active |
| --- | --- | --- |
| VPN | Passed to the kernel, which sends it into the VPN | Blocked (kill switch), or passed if the kill switch is off |
| Direct | Relayed through a connection pinned to the physical interface | Passed unchanged |
| Block | Refused | Refused |

Each flow asks the kernel where it would really go, so a VPN can come up or drop at any
time. Passed flows carry no proxy overhead.

These are deliberately left alone:

- **VPN clients.** Redirecting their encrypted packets would break the VPN.
- **`mDNSResponder`.** See the DNS note below.
- **LAN and overlay destinations** (RFC 1918, 100.64.0.0/10, link-local, ULA). They keep
  their system route, so NetBird and Tailscale peers stay reachable from any app. Block
  still applies to them.

If the extension dies, flows fall back to system routing. With a full-tunnel VPN on
that means the VPN, so a crash cannot expose apps set to VPN.

## Using it

1. Import a WireGuard configuration in Settings and switch it on, or turn on any other
   VPN that takes all traffic.
2. Add apps and choose a route.
3. For "only these apps use the VPN", set **All other apps** to **Direct** (also in the
   menu) and put those apps on **VPN**.

NetBird exit nodes can be switched from the menu too. Turn on **NetBird exit node** in
Settings to show them; it needs the `netbird` CLI.

## Built-in WireGuard

Splyt's system extension also runs WireGuard tunnels using the official WireGuardKit,
so the separate WireGuard app is not needed. In Settings, choose **Import WireGuard
Configuration...** and pick a wg-quick `.conf` file, then switch the tunnel on in
Settings or the menu.

- A tunnel with `AllowedIPs = 0.0.0.0/0, ::/0` takes the default route like any full
  VPN, and app rules split traffic around it as above.
- One tunnel runs at a time; turning one on turns the others off. Turn off any other
  full-tunnel VPN first, since both would claim all traffic.
- Once connected, on-demand keeps the tunnel up across sleep and reboots until it is
  switched off in Splyt.
- Splyt's main switch covers every VPN it controls. Turning Splyt off disconnects the
  WireGuard tunnel and deselects the NetBird exit node if shown; turning it back on reconnects
  whichever was on. Switching a VPN on while Splyt is off turns Splyt on.
- The private key is kept in the login keychain and, for starts without the app, in
  the extension's root-only container. The system VPN preferences file is readable by
  every user, so it only holds the tunnel's name, endpoint and addresses.
- `PostUp`, `Table` and other wg-quick script settings are ignored.

## Limits

- **DNS is not per-app.** Apps resolve names through `mDNSResponder`, so the system
  resolver answers for every app. Direct TCP connections re-resolve the hostname outside
  the VPN when the system supplies it. Apps using their own DNS, such as DNS over HTTPS,
  follow their app's route.
- **Direct UDP changes source ports.** Each peer gets its own socket, so one app socket
  may appear as several ports to remote peers.
- **Firewalls see Direct traffic as Splyt's**, because the extension makes the outbound
  connection.
- **Existing connections keep their path.** Rules apply to new connections, so restart
  an app to move its open ones.

## Routing inside Firefox

Apps can only be split per app, because a browser shares its network process across
tabs. The Firefox extension in `Firefox/extension` goes further and routes each request
by tab, site, container or profile:

| Level | Set in | Scope |
| --- | --- | --- |
| Tab | Toolbar popup | That tab and tabs it opens. Survives a restart with the tab |
| Site | Popup or settings | The domain and subdomains, including what its pages load |
| Container | Popup or settings | Every tab in that container |
| Profile | Popup | Everything else. Each Firefox profile has its own settings |

The most specific level wins, in the order above. Each one chooses VPN, Direct, Block or
Normal, where Normal means the request follows Firefox's app rule.

The Mac app runs two SOCKS5 listeners on 127.0.0.1, one pinned to the tunnel and one to
the physical interface, protected by a password. The extension sends each request to one
of them, with DNS resolved on the same route. Both listeners live in the system
extension, so they stop when Splyt is off.

### Set it up

1. In Splyt, open Settings, turn on **Browser proxy** and copy the pairing code.
2. Install the extension (see below) and paste the code into its settings.
3. In `about:addons`, allow Splyt in private windows if you want it to apply there.
4. Set Firefox's app rule in Splyt to the route you want when the extension cannot act,
   usually **VPN**.

### Failure behaviour

- If Splyt is off, unpaired, or the password is wrong, tabs on VPN or Direct fail to load.
  They never fall back to another route.
- If no tunnel is available, tabs on VPN fail regardless of the kill switch setting.
- Firefox's own requests (updates, telemetry, safe browsing) are never proxied. When a
  proxied system request fails, Firefox can disable all of an extension's proxies for 48
  hours, which would silently move every routed tab to its normal path.

### Firefox limits

- **Normal traffic still follows the app rule.** This covers requests before the extension
  starts, certificate checks, and tabs in private windows if Splyt is not allowed there.
- **WebRTC** cannot use the SOCKS listeners. Leak protection stops it leaving outside the
  proxy, which can break direct peer-to-peer calls. It can be turned off in settings.
- **HTTP/3 and other UDP** do not go through SOCKS here, so proxied pages use TCP.
- **Tabs share one identity.** Routing changes the network path, not cookies or
  fingerprint. Use containers to stop sites linking two routes.
- **Open connections are not moved.** Reload a tab after changing its route.

### Install and test

Release Firefox only keeps signed extensions. `Firefox/sign.sh` signs an unlisted build
with addons.mozilla.org, so it never appears in public search. It reads
`WEB_EXT_API_KEY` and `WEB_EXT_API_SECRET` from `Firefox/.env`, which git ignores, and
bumps the patch version first. Use `Firefox/sign.sh keep` to sign the current version.
AMO never accepts the same version twice. If signing stops after the upload, run
`node Firefox/scripts/amo.mjs fetch <version> <out.xpi>` instead of uploading again.

`Firefox/scripts/release.sh` signs a build, publishes the `.xpi` as a release on
`trajche/splyt-firefox`, and updates that repo's `updates.json`. Installed copies check it
daily. That repo holds only release files, but anyone with the link can download them.

For an unsigned build, `scripts/firefox-extension.sh` makes an `.xpi` for Firefox
Developer Edition, with `xpinstall.signatures.required` set to `false`. For a quick trial
in any Firefox, load `manifest.json` from `about:debugging`; that lasts until Firefox
restarts.

```sh
node --test Firefox/test/rules.test.cjs
(cd SplytCore && swift build --product splyt-socks)
node Firefox/test/e2e.mjs                  # real Firefox, needs a VPN on the default route
```

## Project layout

- `SplytCore/`: policy, routing lookups and flow bridges, with tests. No signing needed.
- `Extension/`: the system extension: the transparent proxy and the WireGuard tunnel.
- `App/`: the SwiftUI menu bar app.
- `Firefox/`: the browser extension and its tests.
- `scripts/release.sh`: signed, notarized build.
- `scripts/build-wireguard.sh`: fetches WireGuardKit at a pinned commit into
  `Vendor/`, applies `scripts/wireguard-apple.patch`, and builds `libwg-go.a`. Needs Go.
- `scripts/firefox-extension.sh`: packages and optionally signs the extension.
- `scripts/github-secrets.sh`: uploads signing and notary credentials for CI.
- `.github/workflows/`: `ci.yml` tests and builds unsigned on every push; `release.yml`
  makes the signed, notarized build.

## Build and test

```sh
(cd SplytCore && swift test)
(cd SplytCore && swift run splyt-probe)   # checks routing on the live network
scripts/build-wireguard.sh                 # once, and after changing the pinned commit
xcodegen generate
xcodebuild -project Splyt.xcodeproj -scheme Splyt -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

Installing requires a signed build. Create the App IDs, profiles and notary credentials
once, as described at the top of `scripts/release.sh`, then run `scripts/release.sh`.

## Updates

Splyt updates itself with [Sparkle](https://sparkle-project.org). It checks
`https://github.com/trajche/splyt/releases/latest/download/appcast.xml` once a day; the
Release workflow attaches that file to every GitHub release, so no other server is
involved. Settings has the switches and a **Check for Updates...** button, and the menu
shows when an update is waiting.

An update is installed only if its archive carries an Ed25519 signature from the key in
`SUPublicEDKey`, and its code signature matches the installed app. `scripts/sparkle-key.sh`
creates that key once: the public half goes into `App/Info.plist`, the private half into
the login keychain and the `SPARKLE_ED_PRIVATE_KEY` secret. If the private key is lost,
installed copies cannot be updated and must be reinstalled by hand.

Keep that key for good. Never run `scripts/sparkle-key.sh --replace` on a released app:
every installed copy trusts only the current key, so a new one cuts them all off. The
keychain item (service `com.amplify2.splyt.sparkle`) is the backup; if the secret goes
missing, put it back without the key touching disk or the screen:

```sh
security find-generic-password -s com.amplify2.splyt.sparkle -a sparkle-ed25519 -w \
    | base64 -d | gh secret set SPARKLE_ED_PRIVATE_KEY --repo trajche/splyt
```

Back the keychain item up somewhere off this Mac as well, such as a password manager.

To ship an update, raise `MARKETING_VERSION` in `project.yml`, commit, and push a tag
`v<version>`. The Release workflow builds, notarizes and publishes it, and installed copies
pick it up on their next check.

`scripts/sign-sparkle.sh` runs as a build phase and re-signs Sparkle's helper tools with
the Developer ID certificate, which notarization requires.

## GitHub Actions

`release.yml` runs `scripts/release.sh` on a GitHub macOS runner. Pushing a `v*` tag
publishes `Splyt-<version>.zip` as a GitHub release, with the tag as the version; running
it by hand only keeps the zip as a workflow artifact. It needs these secrets, which
`scripts/github-secrets.sh <AuthKey_KEYID.p8>` sets with `gh` from this Mac:

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD` | The Developer ID Application identity the profiles name, with a random password |
| `SPLYT_APP_PROFILE`, `SPLYT_PROXY_PROFILE` | The two Developer ID provisioning profiles |
| `NOTARY_API_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | The App Store Connect API key used for notarization |
| `SPARKLE_ED_PRIVATE_KEY` | The update signing key, set by `scripts/sparkle-key.sh` |

Rerun the script after renewing the certificate or regenerating a profile.
