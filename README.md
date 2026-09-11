# Mislaid Curiosity TomTom

[![Release](https://img.shields.io/github/v/release/Kevinjohn/wow-addon-delve-mislaid-tomtom?include_prereleases&sort=semver)](https://github.com/Kevinjohn/wow-addon-delve-mislaid-tomtom/releases)
[![License: MIT](https://img.shields.io/github/license/Kevinjohn/wow-addon-delve-mislaid-tomtom)](LICENSE)
![Interface](https://img.shields.io/badge/Interface-120100-blue)
![Last commit](https://img.shields.io/github/last-commit/Kevinjohn/wow-addon-delve-mislaid-tomtom)

<!-- Keep the Interface badge above in step with `## Interface` in the .toc. -->

**Never walk past a Mislaid Curiosity again.**

Curiosities are easy to miss: they sit off the path, and the map only shows
them once you are nearly on top of one. Your client knows where they are long
before you can see them.

Inside a Delve, this addon puts a [TomTom](https://www.curseforge.com/wow/addons/tomtom)
waypoint on every curiosity as soon as the client knows about it, points an
idle TomTom arrow at the nearest one, and clears the pin once you have looted
it. A small movable counter tracks the run:

> **Curiosities 2 / 5   +18.4%   Journey +6.0%**

Collected out of revealed, plus what this run has given your companion and
your Delver's Journey, each as a share of a level — so you can see what a
Delve was actually worth. Outside Delves it does nothing at all.

## Install

1. Install [TomTom](https://www.curseforge.com/wow/addons/tomtom). Without it
   you still get the counter, but no waypoints.
2. Download the latest zip from the
   [Releases page](https://github.com/Kevinjohn/wow-addon-delve-mislaid-tomtom/releases)
   and drop the **`MislaidCuriosityTomTom`** folder into
   `World of Warcraft / _retail_ / Interface / AddOns`.
3. `/reload` or restart, and tick it in the AddOns list.

## Settings

Esc > Options > AddOns > **Mislaid Curiosity TomTom** — waypoints, the chat
lines, the counter and its totals, and how close you get before a pin clears.
Everything applies immediately.

The same settings live on **`/mct`**: `on`/`off`, `counter`, `xp`, `companion`,
`journey`, `distance <yards>`, `quiet`, `clear`, `scan`, `id`. Type `/mct` on
its own for the current state, or `/mct debug` if a curiosity went unmarked —
that output is what makes it fixable in a bug report.

---

**Contributing:** bug reports and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Released under the [MIT License](LICENSE).

*Early alpha. If something looks off, that's good to know.*
