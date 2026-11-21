# Git Stage for macOS

Git Stage is a menu-bar port of the staging and commit workflow from the Omarchy GitHub widget. Its tray icon fills when any watched repository has local changes. An exclamation mark means a repository could not be read.

Click the icon, add a checkout with **+**, and select the repository. The popup lists staged and unstaged files. **Stage All** includes new and deleted files. **Commit** saves the current index with your message. Local changes are checked every five seconds, including when the popup is closed.

## Build on macOS

Requires macOS 13 or later, Git, and Xcode 15 or compatible Command Line Tools.

```zsh
./scripts/build-app.zsh
open "dist/Git Stage.app"
```

The app uses your Git config, identity, signing settings, and hooks. It runs Git commands directly with a PATH that includes the usual Homebrew locations. Git hooks run according to their own shebang.

## First launch checks

1. Add a disposable repository and close the popup.
2. Edit a file and check that the icon changes within five seconds.
3. Open the popup, stage the file, then edit it again. Check that the popup reports both staged and unstaged changes.
4. Commit and confirm that only the staged version was saved. Stage and commit the remaining edit, then confirm the icon returns to its clean state.

The project retains the original commits and MIT license from mulmlord's Omarchy plugin.
