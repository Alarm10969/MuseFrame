import SwiftUI

enum MuseumStyle {
    static let margin: CGFloat = 32
    static let gap: CGFloat = 24
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let muted = Color.secondary
}

struct CapsuleControl: ViewModifier {
    var active = false
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 33)
            .background(active ? Color.primary.opacity(0.085) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(active || contrast == .increased ? 0.4 : 0.13), lineWidth: 1))
            .contentShape(Capsule())
    }
}

struct RoundIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.25), in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}
