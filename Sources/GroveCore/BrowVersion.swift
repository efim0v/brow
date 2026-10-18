// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

/// The one version of Brow: the app, the command-line tool and the Workspaces
/// panel's footer all say this. `Scripts/build-brow.sh` writes it into the bundle's
/// Info.plist (`Resources/Info.plist` is the template), and `Scripts/release.sh`
/// refuses to package an app that carries another.
public enum BrowVersion {
    public static let current = "0.4.0"
}
