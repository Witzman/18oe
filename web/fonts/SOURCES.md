# Theme fonts (#98)

Served from our own server (`/fonts/`), never from Google or another host. All four are
SIL Open Font License 1.1 (license texts in `LICENSES/`, copied from the npm packages).
Files are the woff2 builds of the npm packages `@fontsource/<name>`, only weights 400 and 700,
subsets latin and latin-ext (the `unicode-range` in `fonts.css` comes from the package's `unicode.json`).

| Font | Theme | Package version | License |
|---|---|---|---|
| Barlow | Brett (body) | @fontsource/barlow 5.3.0 | OFL-1.1 |
| Barlow Condensed | Brett (head) | @fontsource/barlow-condensed 5.3.0 | OFL-1.1 |
| Old Standard TT | Atlas (head) | @fontsource/old-standard-tt 5.3.0 | OFL-1.1 |
| Source Serif 4 | Atlas (body) | @fontsource/source-serif-4 5.3.1 | OFL-1.1 |

16 woff2 files, 326416 bytes in total (about 319 KiB); the browser loads only the subsets/weights a page uses.
To update: `npm pack @fontsource/<name>`, copy the files and LICENSE, regenerate `fonts.css`.
