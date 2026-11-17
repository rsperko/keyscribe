# Releases, betas, and updaters

The contract a build on this codebase can rely on: the forms release and beta tags take, the order versions
follow, how a fix on a release branch relates to `main`, what an updater that offers betas must do, and what
survives moving between a beta and a release. Upstream's own release mechanics (scripts, appcast, build
numbers) live in `docs/development/areas/build-and-release.md`; nothing here depends on them.

## Tag forms

These forms are stable:

- A **release** is tagged `vX.Y.Z`.
- A **beta** is tagged `vX.Y.Z-beta.N`, with `N` counting up from 1. It always precedes the release `vX.Y.Z`.
- No other tag on this repository starts with `v` followed by a digit.

A beta tag never sits where a release tag is expected: no commit carries two version tags (`release.sh` refuses
to tag a commit that already has one), so a commit is a release, a beta, or neither. To find the nearest
release, ignoring betas:

```
git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*'
```

Releases are tagged on `main`, except a fix released from a release branch (below). Its tag is not in `main`'s
history, so a build that follows only `main` finds it with `git tag --list 'v*' --sort=-v:refname`, not with
`git describe`.

## Version order

Order comes from the versions alone, never from a build number, so it holds for any build's numbering.
`ReleaseVersion` (KeyScribeKit) parses and orders them:

- Versions compare by major, minor, and patch.
- `X.Y.Z-beta.N` precedes `X.Y.Z`, and betas of one version order by `N`.
- A downstream build may append `+I` (an iteration count) to any version. It orders after the same version
  without one and by `I` among them, and never past the next upstream version.

A fix released from a release branch is a patch of the release before it, so it precedes every beta of a later
version. A beta user is not offered it; the beta already has the fix, because every release-branch fix comes
from `main` (below).

## Release branches

A fix to a release while `main` has moved on is made on `release/X.Y`, branched from that release's tag, and
released as the next patch. Every commit on a release branch names where it came from, so a build that follows
only `main` can ship the same fix on its own release line. One of two lines in its message says so:

- `(cherry picked from commit <full sha>)`, naming a commit on `main`, as `git cherry-pick -x` writes it.
- `No main commit: <why>`, for a change that exists only on the release branch.

`release.sh` refuses to tag on a release branch with a commit that has neither.

## An updater that offers betas

An updater plugs in through `AppUpdater` (KeyScribeKit). To offer betas it returns a `BetaUpdateOption`, the
label and help text of the switch, from `betaOption`; with `nil`, the default, Settings shows no beta switch.
The choice is saved as `[updates] beta` in `settings.toml`.

What the app does:

- It calls `setReceivesBetaUpdates(_:)` once at launch with the saved choice, before the user can act, and again
  after every settings change and every reload of `settings.toml`. A call can repeat the current choice.
- When the user turns betas off, it clears the "update available" mark in the menu.

What the updater must do:

- Offer and install only what `UpdateOffer.shouldOffer(installed:candidate:betaOn:)` allows. Nothing older or
  equal is offered; a newer release always is; a newer beta only with betas on. A user who turns betas off
  therefore keeps the installed beta until a newer release arrives, and every install gets every release.
- After betas are turned off, not install or offer a beta it found earlier. If a release is still waiting, report
  it again through `onUpdateAvailable`, since the app cleared the mark.

`UpdateOfferTests` in `Tests/KeyScribeKitTests` states the rule as cases; an updater's own tests can call the
same function with its versions.

## Moving between a beta and a release

A tester can turn betas off and install the release before a beta by hand. What the beta wrote keeps working when
they come back:

- A feature flag the release does not know stays in `[features]` when the release saves `settings.toml`, and is
  on again in the beta. Only a flag listed in `Feature.retiredIds` is dropped.
- A setting or mode key the release does not read is reported in Settings, and the release refuses to save that
  file instead of dropping the key. The file is unchanged when the beta comes back.

A key, table, or flag that has shipped in a beta is never renamed without a migration that carries the old one
over (`docs/development/areas/config-and-storage.md`), so an update never turns a feature off silently.
