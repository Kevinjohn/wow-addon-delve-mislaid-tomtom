# Contributing

Thanks for taking a look. This is a small, single-purpose addon, but bug
reports and pull requests are welcome.

## Reporting a bug

Open an [issue](https://github.com/Kevinjohn/wow-addon-delve-mislaid-tomtom/issues)
using the **Bug report** form. The most useful reports include:

- the **addon version** (shown on the in-game AddOns list, or on the Releases
  page),
- the **WoW build** (`/run print(GetBuildInfo())` in-game),
- any **error text** — enable Lua errors with `/console scriptErrors 1` (or use
  BugSack), and
- for a missing or misplaced waypoint: the output of **`/mct debug`** while
  standing in the Delve. That dump lists every marker the client reports, with
  its name, icon and position, which is what makes a detection bug fixable.

## Local development

The addon is a single file, `MislaidCuriosityTomTom.lua`, plus its `.toc`.
Symlink the repo into your AddOns folder as `MislaidCuriosityTomTom` and
`/reload` to pick up changes. TomTom must be installed.

After cloning, switch on the tracked hooks once:

```sh
git config core.hooksPath hooks
```

`hooks/pre-commit` then runs `scripts/check.sh` before every commit and aborts
the commit if it fails. `git commit --no-verify` overrides it.

## Before opening a pull request

Run the checks locally — they need a Lua 5.1+ interpreter (LuaJIT is fine);
`luacheck` is used when it's on your `PATH` and skipped with a note when it
isn't:

```sh
sh scripts/check.sh
```

That runs `luacheck` (config in `.luacheckrc`) and the behaviour harness
(`tests/run.lua`), which drives the addon through the vignette lifecycle under a
stubbed WoW API and a stubbed TomTom. Please also:

- keep each PR to one self-contained change,
- update [`CHANGELOG.md`](CHANGELOG.md), and
- match the existing style — Lua 5.1, 4-space indentation, conventions encoded
  in `.luacheckrc`.

## Building a release

Releases are built by CI when a `v*` tag is pushed. For a local dry-run, see
`scripts/release.sh`; by default it produces a zip in `.release/` and uploads
nothing.

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
