import Foundation
import SwiftUI

/// The meerkat itself, drawn by hand in a 100 x 130 design space and scaled to
/// whatever frame it is given.
///
/// Everything is laid out in those design units: a head centred at (50, 34) is
/// written as exactly that, and the single scale at the top of the renderer maps
/// it to pixels. That keeps the geometry readable and the proportions stable at
/// any size.
///
/// Every number here is `CGFloat` and every trigonometric value is converted
/// from `Double` at the point of use. Mixing the two reads fine and compiles
/// fine right up until an overload becomes ambiguous, so the types stay boring
/// on purpose.
struct MeerkatCritter: View {

    var mood: Mood

    /// Seconds, always climbing. Every idle motion is a function of this.
    var phase: Double

    /// 0 at rest, 1 at the top of a celebration jump.
    var bounce: Double = 0

    private static let designWidth: CGFloat = 100
    private static let designHeight: CGFloat = 130

    // Fur and features.
    private let sand = Color(red: 0.84, green: 0.66, blue: 0.40)
    private let sandShade = Color(red: 0.71, green: 0.53, blue: 0.30)
    private let belly = Color(red: 0.96, green: 0.90, blue: 0.79)
    private let mask = Color(red: 0.28, green: 0.20, blue: 0.14)
    private let eyeWhite = Color(red: 0.99, green: 0.97, blue: 0.93)
    private let earInner = Color(red: 0.55, green: 0.36, blue: 0.28)

    /// The state colour. Defined once on Mood so the critter and the session
    /// dots can never drift apart.
    private var accent: Color { mood.color }

    var body: some View {
        Canvas { ctx, size in
            let scale = min(
                size.width / MeerkatCritter.designWidth,
                size.height / MeerkatCritter.designHeight)
            ctx.translateBy(
                x: (size.width - MeerkatCritter.designWidth * scale) / 2,
                y: (size.height - MeerkatCritter.designHeight * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            draw(into: &ctx)
        }
        .frame(minWidth: 10, minHeight: 10)
        .accessibilityLabel(Text("Meerkat, \(mood.word)"))
    }

    // MARK: - Motion

    /// A sine wave of the given speed, as a CGFloat in -1...1.
    private func wave(_ speed: Double, offset: Double = 0) -> CGFloat {
        CGFloat(sin(phase * speed + offset))
    }

    /// Whole-body sway. Slow and small when idle, brisker at work.
    private var sway: CGFloat {
        let speed: Double = (mood == .working) ? 1.9 : 1.0
        let amount: CGFloat = (mood == .working) ? 1.4 : 0.9
        return wave(speed) * amount
    }

    /// Breathing, as a tiny vertical squash of the torso.
    private var breath: CGFloat {
        wave(2.1) * 0.8
    }

    /// Head turns side to side while scanning for news; holds still otherwise.
    private var headScan: CGFloat {
        switch mood {
        case .working: return wave(1.35) * 3.4
        case .attention: return wave(6.0) * 1.1
        default: return 0
        }
    }

    /// Vertical offset of the whole animal. Negative is up.
    private var lift: CGFloat {
        var value: CGFloat = 0
        switch mood {
        case .attention:
            // An urgent little bob: up sharply, settle, repeat.
            value -= abs(wave(3.4)) * 3.2
        case .idle:
            value += 2.0  // settles down on its haunches
        case .failed:
            value += 3.0  // slumps
        case .working, .done:
            break
        }
        // The celebration jump, highest at bounce == 1.
        value -= CGFloat(bounce) * 9.0

        // The skull's top edge sits at design y = 11, and the Canvas clips at
        // y = 0. These offsets stack -- one session finishing while another
        // needs you adds the hop to the alert bob -- so clamp the total rather
        // than trusting any single term to be small.
        return max(value, -10)
    }

    /// Eyes shut briefly every few seconds, but only when awake.
    private var blinking: Bool {
        guard mood == .working || mood == .attention || mood == .done else { return false }
        return phase.truncatingRemainder(dividingBy: 4.4) < 0.13
    }

    private var celebrating: Bool {
        mood == .done || bounce > 0.05
    }

    // MARK: - Drawing

    private func draw(into ctx: inout GraphicsContext) {
        let dx = sway
        let dy = lift

        // A soft halo in the mood colour, so the state reads even at a glance
        // from across the desk.
        // Only a third of the vertical motion: a glow is ambient, and at full
        // travel its top edge would clip and leave a flat cut across the top.
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: 14 + dx, y: 8 + dy * 0.3, width: 72, height: 116)),
            with: .color(accent.opacity(mood == .idle ? 0.10 : 0.17)))

        drawTail(into: &ctx, dx: dx, dy: dy)
        drawEars(into: &ctx, dx: dx, dy: dy)
        drawBody(into: &ctx, dx: dx, dy: dy)
        drawFeet(into: &ctx, dx: dx, dy: dy)
        drawArms(into: &ctx, dx: dx, dy: dy)
        drawHead(into: &ctx, dx: dx, dy: dy)
        drawMoodExtras(into: &ctx, dx: dx, dy: dy)
    }

    private func drawTail(into ctx: inout GraphicsContext, dx: CGFloat, dy: CGFloat) {
        // Sweeps out behind the hips and hangs down, flicking while busy.
        let flick: CGFloat = (mood == .working) ? wave(2.6) * 4.0 : wave(0.9) * 1.6
        let tipX: CGFloat = 15 + dx - flick * 0.4
        let tipY: CGFloat = 74 + dy - flick

        var tail = Path()
        tail.move(to: CGPoint(x: 42 + dx, y: 108 + dy))
        tail.addCurve(
            to: CGPoint(x: tipX, y: tipY),
            control1: CGPoint(x: 24 + dx, y: 114 + dy),
            control2: CGPoint(x: 12 + dx, y: 98 + dy))
        ctx.stroke(
            tail,
            with: .color(sandShade),
            style: StrokeStyle(lineWidth: 9, lineCap: .round))

        // Dark tip, the way a real one is dipped in black.
        var tip = Path()
        // Follows the curve's own end tangent: evaluating the Bezier above at
        // this height gives x ~ 14.6, not the ~19 you would guess from the
        // control points.
        tip.move(to: CGPoint(x: 14 + dx - flick * 0.3, y: 84 + dy - flick * 0.7))
        tip.addLine(to: CGPoint(x: tipX, y: tipY))
        ctx.stroke(
            tip,
            with: .color(mask),
            style: StrokeStyle(lineWidth: 9, lineCap: .round))
    }

    private func drawEars(into ctx: inout GraphicsContext, dx: CGFloat, dy: CGFloat) {
        // Perked up when alert, folded down when things have gone wrong.
        let droop: CGFloat = (mood == .failed) ? 6.0 : ((mood == .idle) ? 2.5 : 0)
        let x = dx + headScan
        for side in MeerkatCritter.sides {
            let cx: CGFloat = 50 + side * 21 + x * 0.8
            let cy: CGFloat = 25 + dy + droop
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - 7, y: cy - 6.5, width: 14, height: 13)),
                with: .color(sandShade))
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - 3.5, y: cy - 3.5, width: 7, height: 7)),
                with: .color(earInner))
        }
    }

    private func drawBody(into ctx: inout GraphicsContext, dx: CGFloat, dy: CGFloat) {
        // An upright pear: narrow shoulders, broad haunches.
        let squash = breath
        var torso = Path()
        torso.move(to: CGPoint(x: 50 + dx, y: 44 + dy))
        torso.addCurve(
            to: CGPoint(x: 26 + dx, y: 102 + dy + squash),
            control1: CGPoint(x: 34 + dx, y: 48 + dy),
            control2: CGPoint(x: 24 + dx, y: 74 + dy))
        torso.addCurve(
            to: CGPoint(x: 74 + dx, y: 102 + dy + squash),
            control1: CGPoint(x: 30 + dx, y: 118 + dy + squash),
            control2: CGPoint(x: 70 + dx, y: 118 + dy + squash))
        torso.addCurve(
            to: CGPoint(x: 50 + dx, y: 44 + dy),
            control1: CGPoint(x: 76 + dx, y: 74 + dy),
            control2: CGPoint(x: 66 + dx, y: 48 + dy))
        torso.closeSubpath()
        ctx.fill(torso, with: .color(sand))

        // Pale belly.
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: 34 + dx, y: 62 + dy, width: 32, height: 42 + squash)),
            with: .color(belly))
    }

    private func drawFeet(into ctx: inout GraphicsContext, dx: CGFloat, dy: CGFloat) {
        for side in MeerkatCritter.sides {
            let cx: CGFloat = 50 + side * 11 + dx
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: cx - 9, y: 112 + dy + breath, width: 18, height: 11)),
                with: .color(sandShade))
        }
    }

    private func drawArms(into ctx: inout GraphicsContext, dx: CGFloat, dy: CGFloat) {
        // Held politely at the chest, thrown up in the air on a win.
        for side in MeerkatCritter.sides {
            let degrees: Double = Double(side) * (celebrating ? 48 : 12)
            let anchorX: CGFloat = 50 + side * 15 + dx
            let anchorY: CGFloat = (celebrating ? 60 : 66) + dy
            ctx.drawLayer { layer in
                layer.translateBy(x: anchorX, y: anchorY)
                layer.rotate(by: .degrees(degrees))
                // +y is down, so the resting arm hangs from y -3 to +20. Rotating
                // it by 48 degrees would still leave it pointing downward, both
                // arms converging on the belly, so a raised arm has to be the
                // rect flipped to run upward from the shoulder.
                layer.fill(
                    Path(roundedRect: CGRect(x: -4, y: celebrating ? -20 : -3,
                                             width: 8, height: 23),
                         cornerRadius: 4),
                    with: .color(sandShade))
            }
        }
    }

    private func drawHead(into ctx: inout GraphicsContext, dx: CGFloat, dy: CGFloat) {
        let centreX: CGFloat = 50 + dx + headScan
        let centreY: CGFloat = 34 + dy
        let tilt: Double = (mood == .failed) ? 9 : 0

        ctx.drawLayer { layer in
            layer.translateBy(x: centreX, y: centreY)
            layer.rotate(by: .degrees(tilt))

            // Skull.
            layer.fill(
                Path(ellipseIn: CGRect(x: -23, y: -23, width: 46, height: 45)),
                with: .color(sand))

            // Muzzle, a shade lighter, with the nose on the end.
            layer.fill(
                Path(ellipseIn: CGRect(x: -11, y: 2, width: 22, height: 19)),
                with: .color(belly))
            layer.fill(
                Path(ellipseIn: CGRect(x: -4, y: 12, width: 8, height: 6)),
                with: .color(mask))

            drawFace(into: &layer)
        }
    }

    /// The dark eye patches and whatever the eyes are doing. Drawn in head-local
    /// coordinates, where (0, 0) is the centre of the skull.
    private func drawFace(into layer: inout GraphicsContext) {
        let patchWide: CGFloat = (mood == .attention) ? 21 : 19

        for side in MeerkatCritter.sides {
            let cx: CGFloat = side * 10
            let cy: CGFloat = -3

            // The bandit mask every meerkat wears, angled outward.
            layer.drawLayer { patch in
                patch.translateBy(x: cx, y: cy)
                patch.rotate(by: .degrees(Double(side) * 14))
                patch.fill(
                    Path(ellipseIn: CGRect(
                        x: -patchWide / 2, y: -7.5, width: patchWide, height: 15)),
                    with: .color(mask))
            }

            if blinking {
                drawClosedEye(into: &layer, x: cx, y: cy, curve: 0)
                continue
            }

            switch mood {
            case .idle:
                // Dozing: eyes as soft downward slits.
                drawClosedEye(into: &layer, x: cx, y: cy, curve: 1.6)

            case .done:
                // Happy squint, curving up.
                drawClosedEye(into: &layer, x: cx, y: cy, curve: -2.6)

            case .failed:
                // Flat, tired lines.
                drawClosedEye(into: &layer, x: cx, y: cy, curve: 0)

            case .working, .attention:
                let r: CGFloat = (mood == .attention) ? 4.4 : 3.6
                layer.fill(
                    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                    with: .color(eyeWhite))
                // The pupil drifts with the scan, so the gaze leads the head.
                let look: CGFloat = (mood == .working) ? wave(1.35) * 1.1 : 0
                let pupil: CGFloat = r * 0.52
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: cx + look - pupil, y: cy - pupil * 0.8,
                        width: pupil * 2, height: pupil * 2)),
                    with: .color(mask))
            }
        }
    }

    /// One eye as a stroked arc. `curve` bends it: negative smiles, positive sulks.
    private func drawClosedEye(
        into layer: inout GraphicsContext, x: CGFloat, y: CGFloat, curve: CGFloat
    ) {
        var line = Path()
        line.move(to: CGPoint(x: x - 4.6, y: y))
        line.addQuadCurve(
            to: CGPoint(x: x + 4.6, y: y),
            control: CGPoint(x: x, y: y + curve * 2))
        layer.stroke(
            line,
            with: .color(eyeWhite),
            style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
    }

    private func drawMoodExtras(into ctx: inout GraphicsContext, dx: CGFloat, dy: CGFloat) {
        let x = dx + headScan

        switch mood {
        case .attention:
            // A bang above the head, pulsing gently.
            let pulse: Double = 0.72 + 0.28 * abs(sin(phase * 3.4))
            // Radius 9 centred at y = 13, so the top edge is at y = 4 + dy and
            // dy never goes below -3.2. The canvas clips at y = 0 and both call
            // sites scale so design y=0 is canvas y=0, so there is no slack here:
            // a badge centred any higher gets its top sliced off every frame.
            let bx: CGFloat = 74 + x
            let by: CGFloat = max(9.5, 13 + dy)
            ctx.fill(
                Path(ellipseIn: CGRect(x: bx - 9, y: by - 9, width: 18, height: 18)),
                with: .color(accent.opacity(pulse)))
            ctx.fill(
                Path(roundedRect: CGRect(x: bx - 1.5, y: by - 5, width: 3.0, height: 6.2),
                     cornerRadius: 1.5),
                with: .color(.white))
            ctx.fill(
                Path(ellipseIn: CGRect(x: bx - 1.6, y: by + 2.6, width: 3.2, height: 3.2)),
                with: .color(.white))

        case .done:
            // Three sparkles, each on its own little rhythm.
            for spark in MeerkatCritter.sparkles {
                let twinkle: Double = 0.35 + 0.65 * abs(sin(phase * 2.4 + spark.offset))
                let r: CGFloat = 2.0 + CGFloat(twinkle) * 1.8
                let sx: CGFloat = spark.x + x
                let sy: CGFloat = spark.y + dy
                var star = Path()
                star.move(to: CGPoint(x: sx, y: sy - r))
                star.addLine(to: CGPoint(x: sx, y: sy + r))
                star.move(to: CGPoint(x: sx - r, y: sy))
                star.addLine(to: CGPoint(x: sx + r, y: sy))
                ctx.stroke(
                    star,
                    with: .color(accent.opacity(twinkle)),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }

        case .idle, .working, .failed:
            break
        }
    }

    /// Left and right, as a multiplier for mirrored features.
    private static let sides: [CGFloat] = [-1, 1]

    private struct Sparkle {
        let x: CGFloat
        let y: CGFloat
        let offset: Double
    }

    private static let sparkles: [Sparkle] = [
        Sparkle(x: 78, y: 16, offset: 0.0),
        Sparkle(x: 22, y: 24, offset: 1.1),
        Sparkle(x: 84, y: 52, offset: 2.2),
    ]
}
