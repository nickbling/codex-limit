# Codex Limit

Weekly Codex usage in the macOS menu bar, with a clock and percentage on a dim lock screen.

Your wallpaper stays until the locked display sleeps. Then the app shows white text on black, dims the screen to 0.1%, turns off the keyboard light and hides the cursor. Input restores the previous brightness and lock screen without unlocking your Mac.

Updates each minute. Missing or stale usage shows `--`. The menu bar app must stay running.

## Install

Requires macOS 26, Xcode 26 with Swift 6.2, and [Codex CLI](https://github.com/openai/codex) on your PATH.

```sh
codex login
./install.sh
```

Installs to `~/Applications`, or updates an existing `/Applications` copy. Starts at login. Reinstall if you move Codex CLI.

In System Settings, select **Codex Limit** for the native screen saver and disable lock screen notifications. The installer leaves these settings to you.

## Checks

Build and test without installing:

```sh
./install.sh --check
./install.sh --minute    # also check the next clock minute
./install.sh --hardware  # briefly dim and restore the screen and keyboard
```

Build files are temporary. No extra libraries or test framework.

## Limits

Tested on an M4 Pro MacBook with macOS 26.6.2. Uses private macOS APIs and only enables macOS 26. Other hardware is untested. External displays need native brightness support.

Keeping the panel on uses battery. This is not a hardware always-on display. Password, Touch ID and wallpaper stay unchanged. Brightness is saved locally for crash recovery. Account credentials are not copied.

## Remove

Quit the app first to restore brightness, then:

```sh
launchctl bootout "gui/$(id -u)/local.codex-limit"
rm -rf "$HOME/Applications/Codex Limit.app" \
  "$HOME/Library/Screen Savers/Codex Limit.saver" \
  "$HOME/Library/LaunchAgents/local.codex-limit.plist"
```

Use `/Applications` instead if your app is there.

[MIT license](LICENSE). Not affiliated with OpenAI.
