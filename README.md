# Git Stage for macOS

Git Stage is a menu-bar port of the staging and commit workflow from the Omarchy GitHub widget. Its tray icon fills when any watched repository has local changes. An exclamation mark means a repository could not be read.

Click the icon, add a checkout with **+**, and expand a repository card. Each expanded checkout has its own staged and unstaged file list, draft commit message, and **Stage All** action. Local changes are checked every five seconds, including when the popup is closed.

## Build and run

### Requirements

- macOS 13 Ventura or later
- Xcode 15 or newer, or the matching Command Line Tools
- Git available on `PATH`

Check the toolchain:

```zsh
xcode-select --install # only if Command Line Tools are not installed
git --version
swift --version
```

### Development build

Compile the Swift package without creating an app bundle:

```zsh
swift build
```

### App bundle

Build the menu-bar app, ad-hoc sign it, and open it:

```zsh
./scripts/build-app.zsh
open "dist/Git Stage.app"
```

To replace a running local build, quit **Git Stage** from its `…` menu, then run the two commands again. The build output is ignored by Git and lives at `dist/Git Stage.app`.

The app uses your Git config, identity, signing settings, and hooks. It runs Git commands directly with a PATH that includes the usual Homebrew locations. Git hooks run according to their own shebang. It does not transmit repository contents or credentials.

## Using Git Stage

1. Click **+** → **Add a Repository…** to add one checkout, or **Watch a Folder…** to discover checkouts in that folder and its direct subfolders.
2. Click a repository card to expand it. Only that checkout’s files can be staged or committed in the expanded section.
3. Write a commit message and commit. Draft messages are retained separately for each repository while the app stays open.

Nested Git checkouts are treated as separate repositories: a parent repository’s status and **Stage All** action skip nested checkout folders.

## Release checklist

Before sharing a build:

1. Run `swift build` and `./scripts/build-app.zsh` successfully.
2. Add a disposable repository, make a staged and an unstaged edit, and confirm they are reported separately.
3. Stage and commit a change in each of two different repositories. Confirm their messages and files remain isolated.
4. Check a repository containing another checkout. The child checkout must not appear in the parent’s changes or be staged by its **Stage All** button.
5. Test a commit that intentionally fails (for example, no Git identity configured) and make sure the error is understandable.
6. Use **Quit Git Stage**, relaunch it, and confirm the repository list persists.

## Known limits

- The app currently stages all eligible changes in one selected repository; individual-file staging is not implemented yet.
- It does not fetch, push, pull, show GitHub PRs, or use the GitHub API.
- It is ad-hoc signed for local development. Distribution outside your own Mac will need a Developer ID signing and notarization plan.

The project retains the original commits and MIT license from mulmlord's Omarchy plugin.
