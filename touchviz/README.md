# Touch-Viz

Displays visual indicators for touch interactions on iOS.

## Compatibility

- iOS 15.0–26.0.1
- Legacy (rootful), rootless, and roothide jailbreaks

## Build

Requires Xcode 16 and Theos.

```sh
# Legacy (rootful)
source devkit/env.sh
make clean package FINALPACKAGE=1

# Rootless
source devkit/rootless.sh
make clean package FINALPACKAGE=1

# RootHide
source devkit/roothide.sh
make clean package FINALPACKAGE=1
```

The scripts assume `$HOME/theos` and `$HOME/theos-roothide`. Export `THEOS` after sourcing to use another checkout.

## Credits

- @LeoNatan: [LNTouchVisualizer](https://github.com/LeoNatan/LNTouchVisualizer) (MIT)
- Ivan Izyumkin: [MCEmojiPicker](https://github.com/izyumkin/MCEmojiPicker) (MIT)
