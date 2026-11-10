# WatchLoader

An iPhone app that installs apps on its paired **Apple Watch** — no Mac, no paid developer account for the watch apps.

```
WatchLoader ──loopback VPN (10.7.0.1)──► iPhone lockdownd  (+ heartbeat)
            ──com.apple.companion_proxy──► watch lockdownd
            ──com.apple.streaming_zip_conduit──► app installed on the watch
```

- `core/` – Rust (MIT, built on [idevice](https://github.com/jkcoxson/idevice)) exposing `wl_probe` / `wl_install` over a C ABI.
- `App/` – SwiftUI front end.
- CI builds an **unsigned** IPA; sign it with whatever long-lived certificate you have.

## One-time setup
1. Install **LocalDevVPN** (App Store) and connect it.
2. Put these in WatchLoader's Documents folder (Files app, or over USB):
   - `phone.plist` – pairing record for this iPhone (Wi-Fi connections enabled)
   - `watch.plist` – pairing record for the watch (see `tools/watchlink.py pair` in hello-watch)
   - watch-only `.ipa` files signed with a profile that includes the watch's UDID

Pairing records are private keys: they are git-ignored and never baked into the IPA.

Related: [hello-watch](https://github.com/BasimNasserMu/hello-watch) (`tools/watchlink.py` – same install path from a PC).
