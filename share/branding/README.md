# Photo Wagon icon

The wagon carries a stack of photographs. A sunrise and two broad landscape
shapes stay readable at launcher sizes; the two wheels carry the name without
lettering. Amber and ivory contrast with a deep teal tile on both light and dark
surfaces. The tile has a subtle edge so it remains visible on a dark desktop.

`master.svg` is the editable source. Its `mark` group is the color foreground;
`monochrome` is a separate silhouette with transparent cutouts, so themed Android
launchers can choose both colors. The colored icon keeps the same palette in
light and dark mode.

Regenerate all assets with Python 3 and `rsvg-convert`:

```sh
python3 share/branding/export.py
python3 share/branding/preview.py
```

Outputs include desktop SVG/PNGs, the QML window icon, Android legacy icons at
all five densities, adaptive foreground/background layers, a monochrome Android
vector, a 1024 px export, and a preview on light/dark backgrounds at actual small
sizes. Android applies its own mask; the adaptive layers have no baked-in rounded
tile. The essential mark fits the centered 66 dp safe area of the 108 dp canvas.

The Android resource follows the official
[adaptive icon specification](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive).
The monochrome layer is used when the launcher supports themed icons and the
user enables them.

Run `sh share/install-desktop.sh` to refresh an installed desktop launcher.
Android picks up the resources on the next APK package/install. The embedded
QML window icon updates on the next application build.
