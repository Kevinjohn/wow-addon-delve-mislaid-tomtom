# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- First version. Inside a Delve, sets a TomTom waypoint for every Mislaid
  Curiosity the client reports, matched by the game's vignette ID so far-away
  unnamed markers count too. Points an idle TomTom arrow at the nearest one
  (never a busy arrow, and never a guess when your map position is unknown)
  and removes each waypoint when the curiosity is looted or you leave the Delve.
- Movable on-screen counter, "Curiosities collected / known", for the current
  Delve run. Kept per character across a `/reload`, tied to the instance so a
  new run starts fresh, hidden outside Delves. Collected means flagged looted
  by the game, or vanished while you were within about 40 yards (or after
  your pin on it had cleared); out-of-range curiosities stay known and keep
  their waypoint.
- After a companion experience gain, one chat line: the gain as a percentage of
  the level, how many more like it reach the next level, and where the
  companion stands now.
- Delver's Journey progress gets the same chat line, read from the major
  faction with the Delve reward track (`/mct journey` to hide it).
- The counter also shows the companion experience and Journey progress gained
  this run, each as a share of a level (`/mct xp` to hide them).
- Options panel under Esc > Options > AddOns: tick boxes for waypoints, the
  two chat lines, the counter and the counter's experience total, plus a
  drop-down for the pin clear distance. All apply live.
- `/mct` slash command: on/off, `counter`, `xp`, `companion`, `journey`,
  `distance`, `quiet`, `clear`, `scan`, `debug`, `id`.
- TomTom is an optional dependency: without it the addon loads, says so once
  at login, and still counts.
- Release scaffolding: MIT licence, `.pkgmeta` for the BigWigs packager,
  `.luacheckrc`, `scripts/check.sh` and `scripts/release.sh`, a behaviour test
  harness (`tests/run.lua`), community-health docs, and a GitHub Actions
  release workflow.
