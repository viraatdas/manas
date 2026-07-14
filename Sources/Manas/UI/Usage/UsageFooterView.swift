import SwiftUI

/// Drop-in footer composite: the always-visible usage strip with the
/// expanded panel sliding out above it, all within the same window. Screen 1
/// can embed this directly, or place `UsageStripView` and `UsageDetailPanel`
/// separately (e.g. to put the Ask Claude button on the strip's row) by
/// owning the `isExpanded` binding itself.
struct UsageFooterView: View {
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if isExpanded {
                VStack(spacing: 0) {
                    UsageDetailPanel()
                    Divider()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            UsageStripView(isExpanded: $isExpanded)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
        .background(Color.manasBackground)
    }
}

#Preview("Usage footer") {
    VStack {
        Spacer()
        UsageFooterView()
    }
    .frame(width: 420, height: 560)
    .background(Color.manasBackground)
    .environment(UsageSampleData.store())
}
