---
name: marketing-screenshots
description: Capture the switcher layouts for the site carousel, README or ads. Use when asked for BetterCmdTab screenshots or marketing images.
---

The user's desktop is live state: their wallpaper, icons and windows stay as they are, and every setting you change is restored at the end.

1. Ask which Desktop (Space) to shoot on. Shoot there, on the wallpaper it already has; the user picks the wallpaper, never you.
2. Back up `~/.config/bettercmdtab/config.json`, then set `hideFromScreenSharing` to `false` (with `true` the panel never lands in a capture). Switch layouts with `layoutMode` (`list`, `iconDock`, `windowPreview`) through `jq` on that file; the app reloads it live.
3. Hide desktop icons: `defaults write com.apple.finder CreateDesktop false && killall Finder`.
4. Put the capture run in one script and start it with `nohup … &`. Switching Spaces kills processes attached to your shell, so a foreground run dies with it. The script opens the panel with a held ⌘Tab chord (CGEvent), runs `screencapture -x`, and writes a done-file; poll for that file.
5. Restore: the config backup, `CreateDesktop true` plus `killall Finder`, the original Space.
6. Crop centred on the panel with equal top and bottom margins; grid and list crop tighter than preview. Use `magick` for the crop.
7. Write `web/public/screenshots/{list,grid,preview}.jpg` (2000 px wide, JPEG q82) and the matching `.webp` (`cwebp -q 80`); the carousel loads the WebP, `site.webmanifest` and `web/src/routes/__root.tsx` the JPEG. When the size changes, update the `aspect-[…]` class in `web/src/routes/index.tsx` and `sizes` in `web/public/site.webmanifest`.

**Done when** all three images are written, read back and checked for clipping and desktop icons, and the user's config, desktop icons and Space are back as they were.
