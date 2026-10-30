# GlassView

GlassView allows you to have transparent windows open on Mac. It puts an overlay over a window and blends a live copy of that window with whatever is behind it, so you can turn the opacity right down and still see your other work through it. The real window sits underneath the overlay, so your clicks and key presses still go to it as normal.

It lives in the menu bar. Click the icon to bring the window up, click anywhere else to hide it again.

## Features

- **Any app.** Pick a target from the right-click menu: a running app, the frontmost app, or any app in Applications. Roblox is the default.
- **Adjustable opacity** from 100% down to 1%, with a slider in the right-click menu.
- **Click away to hide.** Click outside the window (or switch apps) and it hides. "Keep open" turns that off.
- **Window sizes.** Fullscreen (fills the screen under the menu bar), Mini, Tiny, Small and Medium. Drag the window anywhere and it remembers its position for each app.
- **Your input goes to the real window.** The overlay only draws; it never forwards or mirrors your mouse and keyboard.

## Requirements

- macOS 14 (Sonoma) or newer, on Apple silicon or Intel.
- Xcode or the Command Line Tools to build it (`xcode-select --install`).

## Build and run

```sh
git clone <this repo>
cd GlassView
./build.sh
open build/GlassView.app
```

To keep it, drag `build/GlassView.app` into your Applications folder.

The app is signed ad hoc, not with a developer certificate. If macOS refuses to open it, right-click the app, choose Open, then confirm.

## Permissions

GlassView asks for two permissions the first time you use it:

- **Screen Recording**, to capture the target window and the screen behind it.
- **Accessibility**, to size and position the target window.

Allow both in System Settings, Privacy & Security, then quit and reopen GlassView. The build script signs with a fixed identity, so later rebuilds keep the permissions you gave it.

## Using it

- **Left-click** the menu bar icon to show or hide the window.
- **Right-click** for the menu: opacity, target app, window size, keep open, open the target app, and quit.

## Known limits

- **Fullscreen apps.** macOS puts a fullscreen app on its own desktop and does not let other apps move windows between desktops. If the app you are looking through is in true fullscreen, showing the target window switches you to its desktop. Using a maximised window instead of true fullscreen avoids this.
- **Minimum window sizes.** Some apps will not shrink below a minimum. Roblox's is 800 by 632. GlassView cannot make a window smaller than the app allows.
- **Mouse-lock games.** Camera controls that capture the mouse are untested outside Roblox and may behave differently.
- **Transparency is a copy.** The window you see is a captured picture drawn on top of the real one, not a change to the real window. That is why it works without disabling any macOS protections.

## How it works

GlassView runs two ScreenCaptureKit streams: one of the target window, and one of the screen behind it with the target window left out. It draws the two together in a borderless overlay that ignores the mouse, and sets the top layer's opacity. Window position and size come from the Accessibility API.

## Regenerating the icon

```sh
swift scripts/make-icon.swift
iconutil -c icns build-icon/GlassView.iconset -o Resources/AppIcon.icns
```

## Not affiliated

GlassView is an independent project. It is not affiliated with or endorsed by Roblox Corporation or Apple.

## License

MIT. See [LICENSE](LICENSE).
