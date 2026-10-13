import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = MapModel()

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 690 {
                HStack(spacing: 0) {
                    mapArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    controls
                        .frame(width: min(365, geometry.size.width * 0.43))
                }
            } else {
                VStack(spacing: 0) {
                    mapArea
                        .frame(height: max(175, geometry.size.height * 0.48))
                    Divider()
                    controls
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var mapArea: some View {
        ZStack(alignment: .topLeading) {
            FlyoverMapView(model: model)
            VStack(alignment: .leading, spacing: 2) {
                Text("FLYOVER PITCH LAB").font(.caption.weight(.bold))
                Text("Pinch / drag / rotate; apply a camera below")
                    .font(.caption2)
            }
            .padding(9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .padding(10)
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("Flyover カメラ検証")
                    .font(.title3.bold())
                Text("指定値とMapKitが返した実際のカメラ角度を比較します。3DGSを利用しているかは外観の比較が必要です。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                GroupBox("描画方式") {
                    VStack(alignment: .leading, spacing: 7) {
                        Picker("表示", selection: $model.mode) {
                            ForEach(RenderMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("Realistic Imagery は新3DGSの選択スイッチではありません。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("場所") {
                    VStack(spacing: 8) {
                        Picker("都市", selection: $model.city) {
                            ForEach(TestCity.allCases) { city in
                                Text(city.rawValue).tag(city)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: model.city) { city in
                            model.selectCity(city)
                        }
                        HStack {
                            TextField("緯度", value: $model.latitude, format: .number.precision(.fractionLength(6)))
                            TextField("経度", value: $model.longitude, format: .number.precision(.fractionLength(6)))
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.footnote, design: .monospaced))
                    }
                }

                GroupBox("指定カメラ") {
                    VStack(spacing: 11) {
                        sliderRow("Pitch", value: $model.requestedPitch, range: 0...90, step: 1, suffix: "°")
                        sliderRow("距離", value: $model.requestedDistance, range: 50...10000, step: 50, suffix: " m")
                        sliderRow("方位", value: $model.requestedHeading, range: 0...359, step: 1, suffix: "°")
                        HStack(spacing: 8) {
                            Button("89°") { setPitch(89) }
                            Button("90°") { setPitch(90) }
                            Button("適用") { model.apply() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        Button("60° / 1200m / 北にリセット") {
                            model.requestedPitch = 60
                            model.requestedDistance = 1200
                            model.requestedHeading = 0
                            model.apply()
                        }
                        .font(.footnote)
                    }
                }

                GroupBox("実測（MKMapView.camera）") {
                    VStack(spacing: 8) {
                        metric("Pitch", model.actualPitch, suffix: "°")
                        metric("距離", model.actualDistance, suffix: " m")
                        metric("高度", model.actualAltitude, suffix: " m")
                        metric("方位", model.actualHeading, suffix: "°")
                        Divider()
                        if let difference = model.clampDifference {
                            Label(
                                difference > 1 ? "要求より低いPitch（制限の可能性）" : "要求値に近いPitch",
                                systemImage: difference > 1 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(difference > 1 ? .orange : .green)
                        } else {
                            Text("カメラの読取待ち")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let lat = model.observedLatitude, let lon = model.observedLongitude {
                            Text(String(format: "中心 %.6f, %.6f", lat, lon))
                                .font(.caption2.monospacedDigit())
                                .textSelection(.enabled)
                        }
                        Button("実測値をコピー") {
                            UIPasteboard.general.string = measurementReport
                        }
                        .font(.footnote)
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setPitch(_ degrees: Double) {
        model.requestedPitch = degrees
        model.apply()
    }

    private var measurementReport: String {
        String(
            format: "Flyover Pitch Lab / %@\nMode: %@\nCity: %@\nCenter requested: %.6f, %.6f\nPitch requested: %.1f\nPitch actual: %.1f\nDistance actual: %.1f m\nAltitude actual: %.1f m\nHeading actual: %.1f",
            UIDevice.current.systemVersion,
            model.mode.rawValue,
            model.city.rawValue,
            model.latitude,
            model.longitude,
            model.requestedPitch,
            model.actualPitch ?? -1,
            model.actualDistance ?? -1,
            model.actualAltitude ?? -1,
            model.actualHeading ?? -1
        )
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue) + suffix)
                    .monospacedDigit()
            }
            .font(.footnote)
            Slider(value: value, in: range, step: step)
        }
    }

    private func metric(_ title: String, _ value: Double?, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { String(format: "%.1f", $0) + suffix } ?? "—")
                .fontWeight(.semibold)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.footnote)
    }
}
