# SubFont

A subtitle font loader for macOS.

SubFont reads ASS/SSA subtitles, finds matching fonts in your local collection, and loads them temporarily. Keep it open while watching; quit to unload the fonts it registered.

- Add multiple font folders, including subfolders.
- Pick up library changes automatically while running and on the next launch.
- Load subtitles from Finder or drag them into the app.

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
2. Drag in an ASS/SSA file, or choose **Open With > SubFont** in Finder. You can also open multiple subtitles or a subtitle folder.
3. Check the results, then open your video in your player. Leave SubFont running during playback.
4. Close the window or press **Command-Q** to unload the fonts and quit.

If a font is missing, add it to a watched folder. SubFont updates the index and retries automatically. Hover over a result for details; right-click a font name to locate its file.

## Supported files

**Subtitles:** external ASS/SSA files in UTF-8 or BOM-marked UTF-16, up to 64 MiB each. Embedded subtitle tracks are not read.

**Fonts:** TTF, OTF, TTC, and OTC. Matching uses font names and styles declared in the subtitle, including inline font changes.

Fonts are registered through Core Text for the current login session. Whether a player picks them up depends on its font handling; try reopening the player if needed. SubFont does not check for individual missing glyphs.

## Development

Run the checks for subtitle parsing, indexing, font registration, and cleanup:

```sh
swift run SubFontChecks
```

The checks use generated font fixtures included in the repository. No third-party runtime dependencies are required.

Inspired by [FontLoaderSub](https://github.com/yzwduck/FontLoaderSub).
