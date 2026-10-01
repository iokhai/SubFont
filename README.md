# SubFont

A subtitle font loader for macOS.

SubFont reads subtitle files and embedded video subtitles, finds matching fonts, and loads them temporarily. Keep it open while watching; quit to unload the fonts it registered.

- Add multiple font folders, including subfolders.
- Pick up library changes automatically while running and on the next launch.
- Open subtitles or videos from Finder, or drag them into the app.

Built with SwiftUI and AppKit, with native Liquid Glass controls. Requires **macOS 26 or later**. The app interface is currently in Simplified Chinese.

## Build

Use a Swift 6.2+ toolchain with the macOS 26 SDK.

```sh
git clone https://github.com/iokhai/SubFont.git
cd SubFont
zsh scripts/build-app.sh
open dist/SubFont.app
```

The build creates `dist/SubFont.app` and `dist/SubFont.zip` for your Mac's architecture. The app is locally signed and is not notarized.

## Usage

1. Add your font folders using the folder icon in the toolbar.
2. Drag in a subtitle or video, or choose **Open With > SubFont** in Finder. You can also open multiple files or a folder.
3. Check the results, then open your video in your player. Leave SubFont running during playback.
4. Close the window or press **Command-Q** to unload the fonts and quit.

If a font is missing, add it to a watched folder. SubFont updates the index and retries automatically. Hover over a result for details; right-click a font name to locate its file.

MKV font attachments are checked before your font folders. Videos with all required fonts attached can be opened directly. Temporary attachment files are removed on exit.

## Supported files

**Subtitles:** external ASS/SSA files in UTF-8 or BOM-marked UTF-16, up to 64 MiB each.

**Videos:** ASS/SSA tracks in MKV, and tx3g text subtitles in MP4/MOV. All supported subtitle tracks are checked, including font changes within individual lines. Bitmap subtitles need no fonts; other unsupported tracks are reported in the app. Burned-in subtitles cannot be analyzed.

**Fonts:** TTF, OTF, TTC, and OTC. Matching uses font names and styles declared in the subtitle, including inline font changes.

Fonts are registered through Core Text for the current login session. Whether a player picks them up depends on its font handling; try reopening the player if needed. SubFont does not check for individual missing glyphs.

## Development

Run the checks for subtitle parsing, video containers, indexing, font registration, and cleanup:

```sh
swift run SubFontChecks
```

The checks use generated fonts and tiny video fixtures included in the repository. No third-party runtime dependencies are required. Video fixtures can be regenerated with `uv run --with imageio-ffmpeg scripts/generate-media-fixtures.py`.

Inspired by [FontLoaderSub](https://github.com/yzwduck/FontLoaderSub).
