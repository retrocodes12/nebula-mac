Nebula for Mac and iPhone — native Swift apps (SwiftUI, libmpv engine). macOS 13 or later on Apple silicon and Intel; iOS 16 or later, iPad included.

**Install on a Mac**: open `Nebula.dmg`, drag Nebula to Applications. The app is not notarised, so the first time, right-click it and choose **Open** (or allow it in System Settings › Privacy & Security).

**Install on an iPhone**: `Nebula.ipa` is unsigned — there is no Apple developer account behind this — so you sign it with your own free Apple ID using AltStore, SideStore or Sideloadly from a computer, then trust it in Settings › General › VPN & Device Management. Free signing lasts **seven days** at a time; AltStore and SideStore renew it for you. The README has the details.

In this version: add-ons and their catalogs, search and Discover, title pages with seasons and episodes, streams with badges, the player (every common format, protected streams, subtitles from add-ons, audio and subtitle menus, speed, next episode), Continue Watching, My List, mark as watched, and a Nebula profile that syncs add-ons, progress and My List with your TV, phone and browser.

Live streams that come in several qualities start in a few seconds: the app reads the stream's manifest once and hands the player one quality (Settings › Playback › Picture quality picks which).

The phone app is the same app: the same add-on client, the same engine, the same profile and sync, with a tab bar instead of a sidebar and a player built for a finger — tap to wake the controls, double tap either side to skip, drag the scrubber.

These versions were built and checked entirely on build machines — they compile, play a plain file, an HLS playlist, protected DASH and a live protected sports stream there, and every screen was looked at in screenshots. Neither has yet been run on a Mac or a phone on someone's desk. If something is off on yours, please open an issue.
