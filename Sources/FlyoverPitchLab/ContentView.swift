import SwiftUI

struct ContentView: View {
    @StateObject private var model = MapModel()

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                FlyoverMapView(model: model)
                VStack(alignment: .leading, spacing: 4) {
                    Text("FLYOVER PITCH LAB")
                        .font(.caption.weight(.bold))
                    Text("Use mouse/trackpad to inspect the 3D scene")
                        .font(.caption2)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(16)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text("Camera experiment")
                        .font(.title2.bold())
                    Text("Near-horizontal Flyover camera test. Values shown below are read back from MKMapView, not assumed to be accepted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    GroupBox("MAP RENDERER") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Mode", selection: $model.mode) {
                                ForEach(RenderMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            Text("Flyover uses Apple's native MapKit renderer. New 3DGS support is NOT guaranteed by this selection.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("LOCATION") {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Preset", selection: $model.city) {
                                ForEach(TestCity.allCases) { city in
                                    Text(city.rawValue).tag(city)
                                }
                            }
                            .onChange(of: model.city) { newCity in
                                model.selectCity(newCity)
                            }
                            HStack {
                                TextField("Latitude", value: $model.latitude, format: .number.precision(.fractionLength(6)))
                                TextField("Longitude", value: $model.longitude, format: .number.precision(.fractionLength(6)))
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("REQUESTED CAMERA") {
                        VStack(alignment: .leading, spacing: 10) {
                            sliderRow("Pitch", value: $model.requestedPitch,
                                      range: 0...90, step: 1, suffix: "°")
                            sliderRow("Distance", value: $model.requestedDistance,
                                      range: 50...10000, step: 50, suffix: " m")
                            sliderRow("Heading", value: $model.requestedHeading,
                                      range: 0...359, step: 1, suffix: "°")
                            HStack(spacing: 8) {
                                Button("Set 89° + Apply") {
                                    model.requestedPitch = 89
                                    model.apply()
                                }
                                Button("Apply camera") { model.apply() }
                                    .keyboardShortcut(.return, modifiers: .command)
                                    .buttonStyle(.borderedProminent)
                            }
                            Button("Reset: 60° / 1200 m / North") {
                                model.requestedPitch = 60
                                model.requestedDistance = 1200
                                model.requestedHeading = 0
                                model.apply()
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("ACTUAL CAMERA (MapKit READBACK)") {
                        VStack(alignment: .leading, spacing: 9) {
                            metric("Pitch", model.actualPitch, suffix: "°")
                            metric("Distance", model.actualDistance, suffix: " m")
                            metric("Altitude", model.actualAltitude, suffix: " m")
                            metric("Heading", model.actualHeading, suffix: "°")
                            Divider()
                            if let difference = model.clampDifference {
                                if difference > 1.0 {
                                    Label("Pitch lower than requested (possibly clamped)", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                } else {
                                    Label("Pitch is near requested value", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            } else {
                                Text("Waiting for camera updates...")
                                    .foregroundStyle(.secondary)
                            }
                            if let latitude = model.observedLatitude,
                               let longitude = model.observedLongitude {
                                Text(String(format: "Center: %.6f, %.6f", latitude, longitude))
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                            Text("Camera readback does not prove 3DGS rendering. Compare visually with Apple Maps.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 355)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue) + suffix)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func metric(_ title: String, _ value: Double?, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { String(format: "%.1f", $0) + suffix } ?? "—")
                .monospacedDigit()
                .fontWeight(.semibold)
                .textSelection(.enabled)
        }
    }
}
