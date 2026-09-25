//
//  LCAppGridLayout.swift
//  LiveContainerSwiftUI
//
//  Additive support for an optional app grid layout.
//
//  This file is intentionally new rather than a rewrite of `LCAppListView.swift`,
//  because this fork tracks upstream and wants to keep the diff as small and as
//  localised as possible. It only contains:
//    1. `LCAppListLayoutMode` - the persisted list / grid preference.
//    2. `LCAppLayoutContainer` - a tiny container that swaps `LazyVStack` for
//       `LazyVGrid`. It does not know anything about apps, so the caller keeps
//       using the exact same `ForEach` body in both modes.
//
//  Everything that makes an app row interactive (tap to run, double tap for
//  settings, long press / right click context menu, JIT flow, uninstall, ...)
//  lives inside `LCAppBanner` / `LCAppBannerViewController`. Because the grid
//  reuses that very same component, the interactions are inherited by
//  construction instead of being re-implemented. Nothing can be forgotten.
//

import CoreGraphics
import SwiftUI

/// The app list layout chosen by the user.
///
/// The raw value is written to `UserDefaults`, so it must stay stable across
/// releases. The default (`.list`) matches the historical behaviour, so users
/// that upgrade keep the exact same look.
enum LCAppListLayoutMode: String {
    case list
    case grid

    /// Title for the toolbar toggle. It describes the layout the user will get
    /// after tapping, which is the convention already used by the toolbar.
    ///
    /// Both keys live in `Resources/Localizable.xcstrings`, so this stays inside
    /// the upstream localisation system instead of hard coding a language.
    var toggleDisplayName: String {
        switch self {
        case .list:
            return "lc.appList.gridMode".loc
        case .grid:
            return "lc.appList.listMode".loc
        }
    }

    /// SF Symbol for the toolbar toggle, again showing the target layout.
    var toggleSystemImage: String {
        switch self {
        case .list:
            return "square.grid.2x2"
        case .grid:
            return "list.bullet"
        }
    }

    /// The other mode. Used by the toolbar button.
    var toggled: LCAppListLayoutMode {
        switch self {
        case .list:
            return .grid
        case .grid:
            return .list
        }
    }
}

/// Grid metrics. Kept in a small non generic namespace because Swift does not
/// allow static stored properties inside a generic type.
enum LCAppGridMetrics {
    /// Minimum width of a single grid cell. `adaptive` lets SwiftUI derive the
    /// column count from the available width, so a regular iPhone gets three
    /// columns while an iPad or a landscape layout gets more.
    static let minCellWidth: CGFloat = 96
    /// Upper bound of a single grid cell, so tiles do not become huge on an iPad.
    static let maxCellWidth: CGFloat = 160
    /// Spacing between two cells, in both axes.
    static let spacing: CGFloat = 12
}

/// Lays out the same content either as the original vertical list or as a multi
/// column grid.
///
/// `Content` is the caller's `ForEach`. Keeping it generic means the caller does
/// not have to duplicate the row construction or the animations for the two
/// modes: only the container changes.
struct LCAppLayoutContainer<Content: View>: View {
    let mode: LCAppListLayoutMode
    let spacing: CGFloat
    let content: () -> Content

    init(mode: LCAppListLayoutMode, spacing: CGFloat = LCAppGridMetrics.spacing, @ViewBuilder content: @escaping () -> Content) {
        self.mode = mode
        self.spacing = spacing
        self.content = content
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: LCAppGridMetrics.minCellWidth, maximum: LCAppGridMetrics.maxCellWidth), spacing: spacing)]
    }

    var body: some View {
        if mode == .grid {
            LazyVGrid(columns: columns, spacing: spacing) {
                content()
            }
        } else {
            // The original list container, kept byte for byte in behaviour.
            LazyVStack {
                content()
            }
        }
    }
}
