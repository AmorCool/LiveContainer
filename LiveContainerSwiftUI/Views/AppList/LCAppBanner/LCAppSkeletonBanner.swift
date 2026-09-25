//
//  LCAppSkeletonBanner.swift
//  LiveContainerSwiftUI
//

import SwiftUI

struct LCAppSkeletonBanner: View {
    // ESC-BEGIN app list grid layout - defaulted so the existing call site keeps working
    var layoutMode: LCAppListLayoutMode = .list
    // ESC-END

    var body: some View {
        // ESC-BEGIN app list grid layout
        if layoutMode == .grid {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: LCAppBannerRootView.gridIconSize, height: LCAppBannerRootView.gridIconSize)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 56, height: 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: LCAppBannerRootView.gridBannerHeight)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color.gray.opacity(0.1)))
        } else {
            listSkeleton
        }
        // ESC-END
    }

    private var listSkeleton: some View {
        HStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 60, height: 60)
            
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 16)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 150, height: 12)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 8)
            }
            
            Spacer()
            
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 70, height: 32)
        }
        .padding()
        .frame(height: 88)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.gray.opacity(0.1)))
    }
    
}
