# Git Stage for macOS

Git Stage brings mulmlord’s Omarchy GitHub widget to the macOS menu bar, with file-level staging, unstaging, and diff previews built into the popup. Its tray icon fills when any watched repository has local changes. An exclamation mark means a repository could not be read. Up and down arrows total the commits ahead of and behind configured upstreams.

Click the icon, add a checkout with **+**, and expand a repository card. Each expanded checkout has its own staged and unstaged file list, draft commit message, and **Stage All** action. Local changes are checked every five seconds, including when the popup is closed.

## Build and run

### Requirements

- macOS 13 Ventura or later
- Xcode 15 or newer, or the matching Command Line Tools
- Git 2.25 or later available on `PATH`
- Optional for the GitHub panel: GitHub CLI (`gh`) authenticated with `gh auth login` on github.com

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

The app uses your Git config, identity, signing settings, and hooks. It runs Git commands directly with a PATH that includes the usual Homebrew locations. Git hooks run according to their own shebang. Polling reads only local Git state. Sync actions contact your configured Git remote. Opening or refreshing the GitHub panel requests your account data through `gh`.

## Using Git Stage

1. Click **+** → **Add a Repository…** to add one checkout, or **Watch a Folder…** to discover checkouts in that folder and its direct subfolders.
2. Click a repository card to expand it. Only that checkout’s files can be staged or committed in the expanded section.
3. Open a file’s **…** menu to stage it, unstage it, or inspect its staged or unstaged diff. Unstaging preserves working-tree edits. Untracked files can be previewed after staging.
4. Write a commit message and choose **Commit** to commit the selected repository’s index. Drafts stay separate while the app is open.
5. Read the branch and upstream status above the files. **History** shows the last eight commits. Use **Sync** to fetch, pull with `--ff-only`, or push with your Git configuration. Ahead/behind counts reflect the last local update of the upstream ref.
6. Open **GitHub** for your contribution calendar, open pull requests, review requests, and a link to notifications. Choose **Repositories** to return to local work.

Nested Git checkouts are treated as separate repositories: a parent repository’s status and **Stage All** action skip nested checkout folders.

## Release checklist

Before sharing a build:

1. Run `swift test` and `./scripts/build-app.zsh` successfully.
2. Add a disposable repository, make a staged and an unstaged edit, and confirm they are reported separately.
3. Stage and commit a change in each of two different repositories. Confirm their messages and files remain isolated.
4. Check a repository containing another checkout. The child checkout must not appear in the parent’s changes or be staged by its **Stage All** button.
5. Test a commit that intentionally fails (for example, no Git identity configured) and make sure the error is understandable.
6. Use **Quit Git Stage**, relaunch it, and confirm the repository list persists.

## Known limits

- Staging works at file granularity. Diff previews show the first 32 KiB.
- The GitHub panel requires github.com and shows up to ten PRs per list. Sync is manual. Branch CI alerts and a menu-bar notification count from the Omarchy widget are not implemented.
- It is ad-hoc signed for local development. Distribution outside your own Mac will need a Developer ID signing and notarization plan.

The project retains the original commits and MIT license from mulmlord's Omarchy plugin.
