//
//  LCAppBanner.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UIKit

protocol LCAppBannerDelegate {
    func removeApp(app: LCAppModel)
    func installMdm(data: Data)
    func openNavigationView(view: AnyView)
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle?
}

struct LCAppBanner: UIViewControllerRepresentable {
    var delegate: LCAppBannerDelegate

    @ObservedObject var model: LCAppModel

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    private let sharedModel = DataManager.shared.model

    // ESC-BEGIN app list grid layout
    /// Rendering mode of this banner. Defaults to `.list`, so every existing call
    /// site keeps compiling and keeps the original row layout.
    var layoutMode: LCAppListLayoutMode = .list
    // ESC-END

    init(appModel: LCAppModel, delegate: LCAppBannerDelegate, layoutMode: LCAppListLayoutMode = .list) {
        _model = ObservedObject(wrappedValue: appModel)
        self.delegate = delegate
        self.layoutMode = layoutMode
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = LCAppBannerViewController(delegate: delegate, config: LCAppBannerConfiguration(model: model, dynamicColors: dynamicColors, darkModeIcon: darkModeIcon, layoutMode: layoutMode))
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let viewController = uiViewController as? LCAppBannerViewController else {
            return
        }
        viewController.update(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon,
            layoutMode: layoutMode
        )
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        // ESC-BEGIN app list grid layout - report the compact tile height in grid mode
        let height = layoutMode == .grid ? LCAppBannerRootView.gridBannerHeight : LCAppBannerRootView.bannerHeight
        return CGSize(width: width, height: height)
        // ESC-END
    }
}
