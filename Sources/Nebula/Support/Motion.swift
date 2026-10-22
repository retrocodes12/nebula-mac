import SwiftUI

/// Motion that flows (10-22, Android 1.98.0's pass, asked for on every app: "fast but there is no flow to it").
///
/// Pages used to cut: a title opened, Back, a tab — the page was simply there. Now a page opened slides in from the
/// side and fades up, Back sends it out the same way while the page under it fades back, a tab cross-fades, a pressed
/// card gives under the finger or the click, Home's rows ease in as add-ons answer, and a title page's picture settles
/// as it lands. Pictures already faded in (RemoteImage). The system's Reduce Motion turns all of it off.
enum Motion {
    /// a page pushed or popped: a soft spring with no bounce
    static let page = Animation.spring(response: 0.38, dampingFraction: 0.92)
    static let tab = Animation.easeOut(duration: 0.24)
    static let rows = Animation.easeOut(duration: 0.38)
    /// a page arriving comes from the trailing side and fades up; leaving, it goes back the way it came
    static let pageEdge = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(x: 44)),
        removal: .opacity.combined(with: .offset(x: 44)))
    static let rowIn = AnyTransition.opacity.combined(with: .offset(y: 14))
    /// a title page's picture: from a little close to still, over a second
    static let settle = AnyTransition.asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: 1.06)).animation(.easeOut(duration: 1.1)),
        removal: .opacity)
}

/// A card's give under a finger or a click: a little smaller while pressed, springing back on release.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduce ? 0.955 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
