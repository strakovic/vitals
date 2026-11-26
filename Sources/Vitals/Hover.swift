import AppKit
import SwiftUI

// One hover language for the whole app, so anything you can click looks clickable:
// the hand cursor, a soft highlight that fades in, and a small press-in when clicked.

/// Shows the pointing-hand cursor while the pointer is over the view.
private struct PointerCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onHover { now in
                guard now != inside else { return }
                inside = now
                if now { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if inside { NSCursor.pop(); inside = false } }
    }
}

/// A stat, chip or card that opens something: rounded highlight with a faint lime edge on hover.
private struct Clickable: ViewModifier {
    var inset: CGFloat
    var radius: CGFloat
    var action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(Color.white.opacity(hovering ? 0.05 : 0)).padding(inset))
            .overlay(shape.strokeBorder(Theme.lime.opacity(hovering ? 0.22 : 0), lineWidth: 1).padding(inset).allowsHitTesting(false))
            .scaleEffect(pressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.16), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false })
            .onHover { hovering = $0 }
            .pointer()
    }
}

/// A row that is not a button itself: just the soft highlight.
private struct RowHover: ViewModifier {
    var radius: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(hovering ? 0.045 : 0)))
            .animation(.easeOut(duration: 0.16), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Buttons with their own fill (Boost, primary actions): a touch brighter and bigger.
private struct HoverLift: ViewModifier {
    var scale: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.05 : 0)
            .scaleEffect(hovering ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
            .pointer()
    }
}

extension View {
    func pointer() -> some View { modifier(PointerCursor()) }
    /// `inset` grows (negative) or shrinks (positive) the highlight around the content.
    func clickable(inset: CGFloat = 0, radius: CGFloat = 10, _ action: @escaping () -> Void) -> some View {
        modifier(Clickable(inset: inset, radius: radius, action: action))
    }
    func rowHover(radius: CGFloat = 10) -> some View { modifier(RowHover(radius: radius)) }
    func hoverLift(_ scale: CGFloat = 1.03) -> some View { modifier(HoverLift(scale: scale)) }
}

/// A quiet text button (footer, Back): dim at rest, white on a faint pill under the pointer.
struct QuietButton: View {
    var title: String
    var symbol: String?
    var size: CGFloat = 11
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(Theme.regular(size))
            .foregroundStyle(hovering ? .white : Theme.dim)
            .padding(.horizontal, 9).padding(.vertical, 4.5)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointer()
    }
}

/// The Back pill at the top of the Boost and history screens.
struct BackButton: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    .offset(x: hovering ? -1.5 : 0)
                Text("Back").font(Theme.regular(12))
            }
            .foregroundStyle(hovering ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.1 : 0.06)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointer()
    }
}

/// A secondary action: lime outline, fills softly under the pointer.
struct OutlineButton: View {
    var title: String
    var symbol: String
    var active = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Label(title, systemImage: symbol)
            .font(Theme.regular(11.5))
            .foregroundStyle(active || hovering ? Theme.lime : .white.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(shape.fill(Theme.lime.opacity(hovering ? 0.1 : 0.03)))
            .overlay(shape.stroke(Theme.lime.opacity(active || hovering ? 0.55 : 0.28), lineWidth: 1).padding(0.5))
            .contentShape(shape)
            .onTapGesture(perform: action)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .pointer()
    }
}
