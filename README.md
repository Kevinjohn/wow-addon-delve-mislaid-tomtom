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

More detail below: [options](#options), [commands](#commands), [common questions](#common-questions).

---

## Options

Esc > Options > AddOns > **Mislaid Curiosity TomTom**. Every setting is a tick
box, and each one takes effect immediately:

- Set TomTom waypoints
- Announce found curiosities
- Announce companion XP
- Announce Journey progress
- Show the run counter
- Counter shows run totals
- Pin clear distance: off, 5 yards or 10 yards (drop-down)

Hover a box for what it does. The same settings are available from the `/mct` command below.

---

## Commands

Type **`/mct`** (or `/mislaidcuriosity`) in chat.

| Command | What it does |
| --- | --- |
| `/mct` | Show current settings and how many waypoints are active. |
| `/mct on` / `/mct off` | Turn the addon on or off. Off removes its waypoints and hides the counter. |
| `/mct counter [on\|off]` | Show or hide the counter. `/mct counter reset` restarts this run's numbers. |
| `/mct xp [on\|off]` | Show or hide the run totals (companion experience, Journey progress) on the counter. |
| `/mct companion [on\|off]` | Show or hide the "+x%, n more to level up" line after companion experience. |
| `/mct journey [on\|off]` | The same line for Delver's Journey progress. |
| `/mct distance <yards>` | How close you get before TomTom drops the pin. Default 5. `0` keeps the pin until the curiosity is looted. |
| `/mct quiet [on\|off]` | Hide the "spotted" chat line. |
| `/mct clear` | Remove every waypoint the addon has set right now. |
| `/mct scan` | Re-check for curiosities immediately. |
| `/mct debug` | Print what the client is reporting. Paste this into a bug report. |
| `/mct id` | List the marker IDs treated as a Mislaid Curiosity. `/mct id add <n>` / `remove <n>` change the list if a future patch adds a new one. |

Settings are saved account-wide.

---

## Common questions

**Do I need TomTom?**
For the waypoints, yes. This addon only tells TomTom where to point; TomTom
draws the arrow and the pins. Without TomTom the addon loads, prints one
reminder at login, and still shows the counter.

**A curiosity wasn't marked. Why?**
Either the client didn't know its position yet (walk a little closer), or the
game gave it a marker ID the addon doesn't know. `/mct debug` shows every
marker's ID; if the curiosity's row shows an ID the addon doesn't list under
`/mct id`, add it with `/mct id add <n>` and open an issue so it can be built
in.

**What exactly does the counter count?**
"Known" is every curiosity the game has revealed to your client this run,
including ones too far away to see. "Collected" is every known curiosity the
game has since flagged as looted, or that disappeared while you were within
about 40 yards of it (or after your pin on it had already cleared). One that
simply drops out of range stays known and keeps its waypoint. Party members'
pickups count only if you were nearby; one looted while far from you keeps
its waypoint until the run ends or you `/mct clear`.

**Where do the companion and Journey percentages come from?**
The same places the game's own windows read them: your companion's level is
a friendship reputation, and Delver's Journey is a "major faction" with the
Delve reward track. The addon reads the current standing and the level's
thresholds. Both work anywhere, not just in Delves.

**Will it move my TomTom arrow?**
Only if the arrow was idle. A waypoint you set yourself is never overridden.
If several curiosities appear at once and the game can't report your map
position, the arrow is left alone rather than guessed.

**Does it work outside Delves?**
No, on purpose. It only acts while the game reports you're in a Delve, and it
clears its waypoints when you leave.

**Does it message other players or send anything anywhere?**
No. Everything it shows is visible only to you.

**Will it slow down my game?**
No. It does a tiny check when the game updates its map markers and otherwise
sits quietly.

---

**Contributing:** bug reports and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Released under the [MIT License](LICENSE).

*Early alpha. If something looks off, that's good to know.*
