//
//  WorkProviderLoadingView.swift
//  osaurus
//
//  Shown in Work mode while provider/model state is restoring at startup.
//

import SwiftUI

struct WorkProviderLoadingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text("Restoring providers...")
                .font(theme.font(size: CGFloat(theme.titleSize), weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("Loading your previous provider configuration.")
                .font(theme.font(size: CGFloat(theme.bodySize)))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
