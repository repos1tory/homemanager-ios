# HomeManager

Rootless SpringBoard tweak for the iPad 6th generation running iPadOS 17.7.8. While Home Screen icons are in edit mode, tap removable app or Safari “Add to Home Screen” web app icons to select or deselect them. A blue checkmark marks each selection; the top bar shows the count and offers Cancel and Delete.

Delete opens one confirmation alert listing every selected app or web app. HomeManager follows SpringBoard/LaunchServices uninstall eligibility, including offloaded app placeholders. App icons installed through Sileo or Zebra are treated like other registered apps: only application/web clip icons that SpringBoard recognizes and marks removable are exposed. This does not manage Debian packages, tweak bundles, dylibs, daemons, dependencies, or bootstrap components. Deletion uses OS application/icon removal services and never invokes dpkg or removes files directly.

The bar and badges are hidden when SpringBoard exits edit mode or enters the background. Selection cannot be edited during deletion; selection and icon-capability data are retained until the active queue settles. Failed items remain selected only if edit mode is still active. The tweak conditionally hooks SpringBoard's `SBIconView` native `dragInteraction:itemsForBeginningSession:` method only when present with an object return and two object arguments. For a selected source it asks the other selected icon views for their native drag items; if any selected view, interaction, or item list is unavailable, it returns the source icon's normal drag items. Unselected drags remain native. This delegates the move/drop and persistence to SpringBoard rather than changing icon state. Runtime availability and touch-driven grouped-drop behavior have not been verified on iOS 17.7.8; if the method is absent, multi-icon movement remains unsupported and normal dragging is preserved. No install/respring or device test was performed.

## Build

```sh
umask 022
THEOS=/private/var/mobile/Projects/Toolchain/Theos make SHELL=/var/jb/usr/bin/bash package
```

The package targets `iphoneos-arm64`, rootless, with iOS 15.0 as the minimum. The generated `.deb` is written to `packages/`.

## Package identity and rollback

HomeManager is the new package `com.alsinas.homemanager`, version `0.2.0`. It declares `Replaces` and `Conflicts` for the former `com.alsinas.multidelete` package so Debian package managers replace the old package rather than leave both tweaks active. Its dylib/filter are now `HomeManager` / `HomeManager.plist`.

To remove HomeManager:

```sh
sudo /var/jb/usr/bin/dpkg -r com.alsinas.homemanager
sudo /var/jb/usr/bin/sbreload
```

Rollback to the former package requires removing HomeManager first, then installing the saved old `com.alsinas.multidelete` package; do not install both simultaneously. Removing this tweak does not uninstall any selected apps. App deletion occurs only after the explicit Home Screen confirmation.
