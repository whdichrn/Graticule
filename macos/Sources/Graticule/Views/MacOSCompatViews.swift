import SwiftUI

struct AdaptiveEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String?
    @ViewBuilder let actions: () -> Actions

    init(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions
    }

    init(
        _ title: String,
        systemImage: String,
        description: String? = nil
    ) where Actions == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = { EmptyView() }
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let description {
                    Text(description)
                }
            } actions: {
                actions()
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                Text(title)
                    .font(.title3.weight(.semibold))
                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                actions()
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AdaptiveInspectorModifier<InspectorContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let inspectorContent: () -> InspectorContent

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .inspector(isPresented: $isPresented) {
                    inspectorContent()
                        .inspectorColumnWidth(min: 265, ideal: 295, max: 360)
                }
        } else {
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isPresented {
                    Divider()
                    inspectorContent()
                        .frame(minWidth: 265, idealWidth: 295, maxWidth: 340, maxHeight: .infinity)
                }
            }
        }
    }
}

extension View {
    func adaptiveInspector<InspectorContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> InspectorContent
    ) -> some View {
        modifier(AdaptiveInspectorModifier(isPresented: isPresented, inspectorContent: content))
    }
}
