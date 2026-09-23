Nebula for Mac and iPhone — native Swift apps (SwiftUI, libmpv engine). macOS 13 or later on Apple silicon and Intel; iOS 16 or later, iPad included.

**New in 0.3.0** — a full audit pass on both apps. The Mac answers its play/pause keys, headphone controls and Control Center, and the phone's lock screen shows what is playing. Home no longer waits for a slow add-on and never reshuffles the rows you are looking at; add-ons that could not be reached are asked again when the connection comes back, and a streams page says how many did not answer. Subtitles attach once both the video and your add-ons are ready. A film you seek back into after its end plays on instead of starting over, the phone stays awake while a stream is starting, text follows the phone's text size, the title art runs under the status bar, and small buttons take a full-size tap. Progress that reaches the app broken can no longer wipe a resume point.

**Install on a Mac**: open `Nebula.dmg`, drag Nebula to Applications. The app is not notarised, so the first time macOS refuses it: go to System Settings › Privacy & Security and choose **Open Anyway** beside the line about Nebula (on macOS 13 and 14, right-click › **Open** also works).

**Install on an iPhone**: `Nebula.ipa` is unsigned — there is no Apple developer account behind this — so you sign it with your own free Apple ID using AltStore, SideStore or Sideloadly from a computer, then trust it in Settings › General › VPN & Device Management. Free signing lasts **seven days** at a time; AltStore and SideStore renew it for you. The README has the details.

In this version: add-ons and their catalogs, search and Discover, title pages with seasons and episodes, streams with badges, the player (every common format, protected streams, subtitles from add-ons, audio and subtitle menus, speed, next episode), Continue Watching, My List, mark as watched, and a Nebula profile that syncs add-ons, progress and My List with your TV, phone and browser.

Live streams that come in several qualities start in a few seconds: the app reads the stream's manifest once and hands the player one quality (Settings › Playback › Picture quality picks which).

The phone app is the same app: the same add-on client, the same engine, the same profile and sync, with a tab bar instead of a sidebar and a player built for a finger — tap to wake the controls, double tap either side to skip, drag the scrubber.

These versions were built and checked entirely on build machines — they compile, play a plain file, an HLS playlist, protected DASH and a live protected sports stream there, and every screen was looked at in screenshots. Neither has yet been run on a Mac or a phone on someone's desk. If something is off on yours, please open an issue.
