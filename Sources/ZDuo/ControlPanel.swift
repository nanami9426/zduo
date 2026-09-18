import SwiftUI

struct ControlPanel: View {
    @ObservedObject var model: AppModel
    var closePanel: () -> Void
    private let accent = Color(red: 0.60, green: 0.72, blue: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ZDuo").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("让画面留在原处").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用景深", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(accent).help("启用景深")
            }

            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.inputMode == .real ? "屏幕角度" : "模拟角度")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(model.inputMode == .real && model.rawAngle == nil ? "—" : "\(Int(model.displayedAngle.rounded()))")
                            .font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit()
                        Text("°").font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                    }
                    Text("参考平面 \(Int(model.referenceAngle))°")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HingeDrawing(angle: model.displayedAngle, reference: model.referenceAngle, accent: accent)
                    .frame(width: 152, height: 118)
                    .accessibilityLabel("屏幕与参考平面示意图")
            }
            .padding(18)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.06)))

            VStack(spacing: 12) {
                Picker("角度来源", selection: $model.inputMode) {
                    ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Text("15°").foregroundStyle(.secondary)
                    Slider(value: $model.simulatedAngle, in: 15...150, step: 1)
                        .disabled(model.inputMode == .real).tint(accent)
                        .accessibilityLabel("模拟开合角度")
                    Text("150°").foregroundStyle(.secondary)
                }.font(.system(size: 10).monospacedDigit())
                Text(model.inputMode == .real ? "轻轻开合屏幕，角度直接控制景深。" : "拖动滑杆预览；停在哪里，景深就保持在哪里。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 15) {
                VStack(spacing: 6) {
                    HStack {
                        Text("参考角度")
                        Spacer()
                        Button("设为当前") { model.anchorHere() }
                            .buttonStyle(.plain).foregroundStyle(accent)
                            .disabled(model.inputMode == .real && model.rawAngle == nil)
                        Text("\(Int(model.referenceAngle))°").monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    Slider(value: $model.referenceAngle, in: 30...150, step: 1).tint(accent)
                        .accessibilityLabel("参考角度")
                }
                VStack(spacing: 6) {
                    HStack {
                        Text("效果强度")
                        Spacer()
                        Text("\(Int((model.strength * 100).rounded()))%")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $model.strength, in: 0...1).tint(accent).accessibilityLabel("效果强度")
                }
            }.font(.system(size: 12))

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(model.overlayVisible ? Color.mint : accent.opacity(0.55))
                        .frame(width: 6, height: 6).padding(.top, 4)
                    Text(model.captureStatus).fixedSize(horizontal: false, vertical: true)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    if model.overlayVisible, model.fps > 0 {
                        Text("\(Int(model.fps.rounded())) fps")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(model.sensorStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                if model.enabled && !model.permissionGranted {
                    HStack {
                        Button("打开屏幕录制设置") { model.openPrivacySettings() }
                        Button("重新检查") { model.retry() }
                    }.font(.system(size: 11)).controlSize(.small)
                    Text("授权 ZDuo 后重新检查；系统要求重启时，请重新打开应用。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else if model.enabled {
                    Button("重新连接") { model.retry() }
                        .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(accent)
                }
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 0)
            HStack {
                Text(model.shortcutAvailable ? "⌃⌥⌘D  立即停用" : "快捷键被占用，请用开关停用")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("收起") { closePanel() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 11))
        }
        .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 20)
        .frame(width: 380, height: model.enabled && !model.permissionGranted ? 716 : 680)
        .background(Color(red: 0.067, green: 0.075, blue: 0.10))
        .foregroundStyle(Color.white.opacity(0.92))
        .preferredColorScheme(.dark)
    }
}

private struct HingeDrawing: View {
    let angle: Double
    let reference: Double
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let hinge = CGPoint(x: 55, y: size.height - 20)
            let length = 81.0
            func end(_ degrees: Double) -> CGPoint {
                let radians = min(150, max(0, degrees)) * .pi / 180
                return CGPoint(x: hinge.x + cos(radians) * length, y: hinge.y - sin(radians) * length)
            }
            let referenceEnd = end(reference)
            let currentEnd = end(angle)
            var plane = Path()
            plane.move(to: hinge); plane.addLine(to: referenceEnd); plane.addLine(to: currentEnd); plane.closeSubpath()
            context.fill(plane, with: .linearGradient(Gradient(colors: [accent.opacity(0.02), accent.opacity(0.2)]), startPoint: hinge, endPoint: currentEnd))
            var referenceLine = Path()
            referenceLine.move(to: hinge); referenceLine.addLine(to: referenceEnd)
            context.stroke(referenceLine, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            var screen = Path()
            screen.move(to: currentEnd); screen.addLine(to: hinge); screen.addLine(to: CGPoint(x: size.width - 7, y: hinge.y))
            context.stroke(screen, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: hinge.x - 3, y: hinge.y - 3, width: 6, height: 6)), with: .color(.white))
        }
    }
}
