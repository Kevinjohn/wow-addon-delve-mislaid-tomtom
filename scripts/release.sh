#!/usr/bin/env sh
# Build a release zip locally with the BigWigs packager.
#
# Normal releases run in CI: pushing a `v*` tag triggers
# .github/workflows/release.yml, which runs this same packager and also creates
# the GitHub Release (and CurseForge/Wago uploads once configured). This script
# is for local dry-runs — inspecting the zip before you tag.
#
# The addon lives at the repo root (flat layout), which is what the packager
# needs: it discovers the .toc at $topdir/<package-as>.toc. `package-as` in
# .pkgmeta names the folder inside the zip.
#
# By default this runs "dist only" (-d): it builds the zip into .release/ and
# uploads nothing.
#
# To upload from here instead of CI:
#   1. Create the CurseForge / Wago projects and fill X-Curse-Project-ID /
#      X-Wago-ID in MislaidCuriosityTomTom.toc.
#   2. Export the tokens:
#         export CF_API_KEY=...        # CurseForge
#         export WAGO_API_TOKEN=...    # Wago
#         export GITHUB_OAUTH=...      # GitHub personal access token (for the Release)
#   3. Run with your own flags to upload, e.g.  sh scripts/release.sh -p 0000 -a abcd
#
# The packager reads the version from the latest git tag, so tag first:
#   git tag v0.1.0 && git push --tags
set -e

cd "$(dirname "$0")/.."

# Default to a no-upload build unless the caller passes their own flags.
if [ "$#" -eq 0 ]; then
	set -- -d
fi

curl -s https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh | bash -s -- "$@"
