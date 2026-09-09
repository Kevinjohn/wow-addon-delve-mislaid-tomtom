# World of Warcraft Addon Publishing Readiness Checklist

> Goal: Ensure this GitHub repository is fully configured for automated releases to CurseForge and Wago using GitHub Actions and BigWigs Packager.
>
> Repository: ______________________
>
> Date Checked: ____________________
>
> Checked By: ______________________

---

# Phase 1 — Repository Audit

## Basic Structure

- [ ] Repository exists on GitHub.
- [ ] Repository contains addon source code.
- [ ] Repository contains a valid `.toc` file.
- [ ] Addon loads successfully inside World of Warcraft.
- [ ] No obvious build errors exist.
- [ ] No temporary or backup files are committed.

Expected structure:

```text
MyAddon/
├── MyAddon.toc
├── *.lua
├── README.md
└── .github/
```

---

## TOC Validation

Locate:

```text
MyAddon.toc
```

Confirm:

- [ ] `## Title:` exists.
- [ ] `## Author:` exists.
- [ ] `## Notes:` exists.
- [ ] `## Interface:` exists.
- [ ] Interface version is current for supported WoW version.
- [ ] `## Version:` exists.
- [ ] Version uses:

```toc
## Version: @project-version@
```

- [ ] `## X-Curse-Project-ID:` exists.
- [ ] `## X-Wago-ID:` exists.

Example:

```toc
## Version: @project-version@
## X-Curse-Project-ID: 123456
## X-Wago-ID: abc123
```

---

# Phase 2 — Publishing Configuration

## CurseForge

Verify:

- [ ] CurseForge project exists.
- [ ] Correct CurseForge Project ID obtained.
- [ ] Project ID matches TOC.
- [ ] Project is configured as a WoW Addon.
- [ ] Project description exists.
- [ ] Project icon exists (recommended).
- [ ] Source code URL configured.

Reference:

https://authors.curseforge.com/

---

## Wago

Verify:

- [ ] Wago project exists.
- [ ] Correct Wago Project ID obtained.
- [ ] Project ID matches TOC.
- [ ] Project description exists.
- [ ] Source code URL configured.

Reference:

https://addons.wago.io/

---

# Phase 3 — GitHub Secrets

Open:

Repository → Settings → Secrets and Variables → Actions

Verify:

- [ ] CF_API_TOKEN exists.
- [ ] WAGO_API_TOKEN exists.

Confirm:

- [ ] Tokens are not stored in source code.
- [ ] Tokens are not committed to repository.
- [ ] Tokens are not present in README files.
- [ ] Tokens are not present in workflow files.

---

# Phase 4 — Packaging Configuration

## .pkgmeta

Verify file exists:

```text
.pkgmeta
```

Verify:

- [ ] package-as value is correct.
- [ ] Ignore rules are sensible.
- [ ] Development files excluded.
- [ ] GitHub workflow files excluded from release package.

Example:

```yaml
package-as: MyAddon

ignore:
  - .github
  - README.md
```

Reference:

https://github.com/BigWigsMods/packager

---

# Phase 5 — GitHub Actions

Verify workflow exists:

```text
.github/workflows/release.yml
```

Confirm:

- [ ] Workflow uses BigWigs Packager.
- [ ] Workflow triggers on Git tags.
- [ ] Workflow creates GitHub Releases.
- [ ] Workflow uploads to CurseForge.
- [ ] Workflow uploads to Wago.

Reference:

https://github.com/BigWigsMods/packager

---

# Phase 6 — Documentation

Verify:

- [ ] README.md exists.
- [ ] Installation instructions exist.
- [ ] Repository description exists.
- [ ] Licence file exists.
- [ ] Changelog exists or release notes are generated automatically.

Recommended files:

```text
README.md
LICENSE
CHANGELOG.md
```

---

# Phase 7 — Release Validation

Create test tag:

```bash
git tag v0.0.1-test
git push origin v0.0.1-test
```

Verify:

## GitHub

- [ ] Workflow executed successfully.
- [ ] GitHub Release created.
- [ ] Release ZIP attached.

## CurseForge

- [ ] File uploaded successfully.
- [ ] Version visible.
- [ ] Release notes present.
- [ ] No validation errors.

## Wago

- [ ] File uploaded successfully.
- [ ] Version visible.
- [ ] Release notes present.
- [ ] No validation errors.

---

# Phase 8 — Package Verification

Download generated ZIP.

Verify:

- [ ] ZIP extracts correctly.
- [ ] Top-level folder name is correct.
- [ ] TOC file exists inside package.
- [ ] Addon appears in WoW AddOns list.
- [ ] Addon loads without Lua errors.
- [ ] SavedVariables still function correctly.

Expected ZIP structure:

```text
MyAddon.zip
└── MyAddon/
    ├── MyAddon.toc
    ├── MyAddon.lua
    └── ...
```

---

# Phase 9 — Future Release Process

Verify repository supports:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Expected result:

- [ ] GitHub Release created automatically.
- [ ] CurseForge upload created automatically.
- [ ] Wago upload created automatically.
- [ ] No manual ZIP creation required.
- [ ] No manual uploads required.

---

# Final Sign-Off

## Publishing Readiness

- [ ] Repository ready for automated publishing.
- [ ] CurseForge integration working.
- [ ] Wago integration working.
- [ ] GitHub Actions working.
- [ ] Test release completed successfully.

Result:

- [ ] PASS
- [ ] FAIL
