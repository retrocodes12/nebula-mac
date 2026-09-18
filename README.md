# Nebula for Mac

The native macOS app for [Nebula](https://play.rifflehq.in), the streaming player that browses add-ons — catalogs, details, streams, subtitles — and plays what they offer. Written in Swift: SwiftUI for the interface, libmpv for playback.

The other Nebula apps: [web, webOS TV](https://github.com/retrocodes12/nebula-player) · [Android phone and TV](https://github.com/retrocodes12/nebula-android) · [Windows and Linux](https://github.com/retrocodes12/nebula-desktop).

## What it does

- **Add-ons** — install by address or install link, switch off, reorder, remove. Opens with a catalogue already in it.
- **Home** — a full-bleed hero, Continue Watching, a row per catalog in your add-ons' order.
- **Search and Discover** — one search across every add-on; with the field empty, pick a type, a catalog and a genre and page through it.
- **Title pages** — art that dissolves into the page, facts, cast and crew, seasons and episodes inline with ticks, an Up next ring and air dates. Right-click anything to mark it watched or save it.
- **Streams** — one section per add-on; each row led by its resolution plate, with size, rate, languages and badge art read out of the add-on's text.
- **The player** — libmpv with Metal output and hardware decoding: MKV, HEVC, Dolby and DTS sound, HLS, DASH, and protected DASH decrypted on the Mac. Subtitles from the file and from your subtitle add-ons, audio and subtitle menus, speed, a scrubber with a time tip, next episode as the credits start, the keyboard you expect (Space, ← →, ↑ ↓, F, M, C, A, I, N, Esc).
- **A Nebula profile** — an @handle and a password, no email. Signed in, add-ons, watch progress and My List move between this Mac, the TV, the phone and the browser, newest change winning per record. A TV can be signed in from here with its six-character code.

## Install

Download `Nebula.dmg` from [Releases](https://github.com/retrocodes12/nebula-mac/releases/latest), drag Nebula to Applications. macOS 13 or later, Apple silicon or Intel. The app is not notarised: the first time, right-click it and choose **Open**.

## How it is built

```
Sources/NebulaCore   plain Foundation, no UI — builds and tests on Linux as well as macOS
  Stremio.swift        the add-on protocol client (manifests, catalogs, meta, streams, subtitles)
  ClearKey.swift       decryption keys: from the address, the stream row, or the manifest's licence
  Progress.swift       resume points, ticks, the ranked trim, the series cursor
  Library.swift        My List, with removal tombstones
  Cloud.swift          profile + sync client; the wire format is the shared player's, verbatim
  StreamBadges.swift   the plate, badges and facts read out of a stream row's text
Sources/Nebula       the app — SwiftUI + libmpv (through MPVKit), macOS only
  Player/              MPVController (the engine), VideoSurface (its Metal layer), PlayerScreen (the chrome)
  Views/               Home, Search + Discover, title page, streams, catalog, My List, Add-ons, Settings
  Support/             theme, image loading, and the three build-machine modes below
Tests/NebulaCoreTests  28 tests; sync is driven end to end against a stand-in server
```

`swift test` runs the core suite anywhere Swift runs. `scripts/bundle.sh` builds a universal `Nebula.app`, draws its icon, signs it ad hoc and packs a dmg and a zip.

Nobody needs a Mac on their desk to work on this: the app has three command-line modes that CI uses to stand in for one. `Nebula --smoke <address> [--keys kid:key]` plays a stream with no window and exits 0 only if the clock moved; `Nebula --shots <folder>` walks the real window through every screen and writes PNGs; `Nebula --icon <file>` draws the icon.

## Privacy

The app talks to the add-ons you install, to the hosts of the streams and pictures they name, and — only if you sign in — to the Nebula profile service. It has no analytics. The full policy is at [play.rifflehq.in/privacy.html](https://play.rifflehq.in/privacy.html).
