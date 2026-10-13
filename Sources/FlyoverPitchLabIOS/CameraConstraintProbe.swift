import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

/// Experimental public-API camera paths. Does not modify VectorKit or disable
/// system safeguards. Camera readback must be interpreted separately for each
/// API: MKMapCamera and SwiftUI MapCamera use different wrappers.
@MainActor
final class CameraConstraintProbe: ObservableObject {
    static let shared = CameraConstraintProbe()

    enum Path: String, CaseIterable {
        case distance = "MKMapCamera distance+pitch"
        case eye = "MKMapCamera eye+altitude"
        case swiftUI = "SwiftUI Map camera"
    }

    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let path: Path
        let requestedDistance: Double
        let requestedPitch: Double
        let constructorPitch: Double
        let immediatePitch: Double?
        let renderPitch: Double?
        let settledPitch: Double?
        let settledDistance: Double?
        let elapsed: Double
        let renderCallbacks: Int
        let mapErrors: Int
        let status: String
    }

    @Published private(set) var isRunning = false
    @Published private(set) var showSwiftUI = false
    @Published private(set) var progress = 0
    @Published private(set) var status = "未実行"
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var csvURL: URL?
    @Published private(set) var swiftUIRevision = 0
    @Published private(set) var swiftUICamera: MapCamera?

    private let distances: [Double] = [50, 200, 500, 1200, 3000, 10000]
    private weak var mkMap: MKMapView?
    private var work: Task<Void, Never>?
    private var targetCoordinate: CLLocationCoordinate2D?
    private var targetHeading: Double = 0
    private var swiftUIReady = false
    private var swiftUILatest: MapCamera?
    private var swiftUIObservedAt: Date?
    private var renderObserved: Double?
    private var notifiedRendered = false
    private var backgroundObserver: NSObjectProtocol?

    var total: Int { distances.count * Path.allCases.count }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let saved = docs.appendingPathComponent("FlyoverPitchLab/CameraConstraintProbe-latest.csv")
        if FileManager.default.fileExists(atPath: saved.path) {
            csvURL = saved
            status = "以前の比較CSVを読み出せます"
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func register(_ map: MKMapView) { mkMap = map }
    func unregister(_ map: MKMapView) {
        if mkMap === map { mkMap = nil }
    }

    func noteMKRendering(_ map: MKMapView) {
        guard isRunning && !showSwiftUI else { return }
        notifiedRendered = true
        renderObserved = Double(map.camera.pitch)
        DiagnosticLogger.shared.log("PITCH_PROBE", "MK_RENDER_CALLBACK", fields: [
            "observedPitch": "\(map.camera.pitch)",
            "distance": "\(map.camera.centerCoordinateDistance)"
        ])
    }

    func markSwiftUIReady() {
        swiftUIReady = true
        DiagnosticLogger.shared.log("PITCH_PROBE", "SWIFTUI_MAP_APPEARED")
    }

    func swiftUIPositionApplied(_ position: MapCameraPosition) {
        DiagnosticLogger.shared.log("PITCH_PROBE", "SWIFTUI_POSITION_BOUND", fields: [
            "requestedPositionPitch": "\(position.camera?.pitch ?? -1)"
        ])
    }

    func observeSwiftUI(_ camera: MapCamera) {
        guard isRunning && showSwiftUI else { return }
        swiftUILatest = camera
        swiftUIObservedAt = Date()
        // A callback reports actual SwiftUI Map camera state, not tile status.
    }

    func start(model: MapModel, otherSweepRunning: Bool) {
        guard !isRunning && !otherSweepRunning else { return }
        guard mkMap != nil else { status = "MKMapViewが見つかりません"; return }
        let lat = model.latitude, lon = model.longitude
        guard lat.isFinite, lon.isFinite, abs(lat) <= 85, abs(lon) <= 180 else {
            status = "緯度経度が無効です"
            return
        }
        targetCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        targetHeading = model.requestedHeading.isFinite ? model.requestedHeading : 0
        progress = 0
        samples = []
        csvURL = nil
        isRunning = true
        showSwiftUI = false
        swiftUIReady = false
        status = "比較を開始"
        DiagnosticLogger.shared.log("PITCH_PROBE", "RUN_STARTED", fields: [
            "latitude": "\(lat)", "longitude": "\(lon)",
            "requestedPitch": "89", "heading": "\(targetHeading)",
            "distances": distances.map { String(Int($0)) }.joined(separator: ","),
            "paths": Path.allCases.map(\.rawValue).joined(separator: ";")
        ])
        work = Task { [weak self, weak model] in
            guard let self, let model else { return }
            await self.run(model: model)
        }
    }

    func stop() {
        guard isRunning else { return }
        work?.cancel()
        status = "停止処理中（保存済み行は保持）"
        DiagnosticLogger.shared.log("PITCH_PROBE", "STOP_REQUESTED", fields: [
            "done": "\(progress)", "total": "\(total)"
        ])
    }

    private func run(model: MapModel) async {
        let diag = DiagnosticLogger.shared
        guard let center = targetCoordinate else { return }
        for path in [Path.distance, .eye] {
            if Task.isCancelled { break }
            guard let map = mkMap else { break }
            map.mapType = .satelliteFlyover
            for d in distances {
                if Task.isCancelled { break }
                let requestedPitch = 89.0
                let camera: MKMapCamera
                if path == .distance {
                    camera = MKMapCamera(lookingAtCenter: center, fromDistance: d,
                                         pitch: CGFloat(requestedPitch), heading: targetHeading)
                } else {
                    // Pick an eye nearly level with the target. Sightline is
                    // nominally 89° below the horizon-free right angle, but
                    // terrain/elevation and camera construction may clamp it.
                    let radians = requestedPitch * .pi / 180
                    let horizontal = d * sin(radians)
                    let altitude = max(0.1, d * cos(radians))
                    let eye = coordinate(from: center, distance: horizontal,
                                         bearing: targetHeading + 180)
                    camera = MKMapCamera(lookingAtCenter: center,
                                         fromEyeCoordinate: eye, eyeAltitude: altitude)
                }
                let constructed = Double(camera.pitch)
                let start = Date()
                let errorsBefore = diag.errorCount
                let rendersBefore = diag.renderCount
                notifiedRendered = false
                renderObserved = nil
                status = "\(path.rawValue) / \(Int(d)) m"
                diag.log("PITCH_PROBE", "CONSTRUCTED", fields: [
                    "path": path.rawValue, "requestedDistance": "\(d)",
                    "requestedPitch": "\(requestedPitch)",
                    "constructorPitch": "\(constructed)",
                    "constructorDistance": "\(camera.centerCoordinateDistance)",
                    "constructorAltitude": "\(camera.altitude)"
                ])
                map.setCamera(camera, animated: false)
                let immediate = Double(map.camera.pitch)
                diag.log("PITCH_PROBE", "AFTER_APPLY", fields: [
                    "path": path.rawValue, "distance": "\(d)",
                    "immediatePitch": "\(immediate)"
                ])
                do { try await Task.sleep(nanoseconds: 1_700_000_000) }
                catch { break }
                if Task.isCancelled { break }
                let settled = Double(map.camera.pitch)
                let renderCount = max(0, diag.renderCount - rendersBefore)
                let errors = max(0, diag.errorCount - errorsBefore)
                let classification = classify(expected: requestedPitch, actual: settled,
                                                errors: errors)
                let s = Sample(time: Date(), path: path, requestedDistance: d,
                               requestedPitch: requestedPitch, constructorPitch: constructed,
                               immediatePitch: immediate,
                               renderPitch: notifiedRendered ? renderObserved : nil,
                               settledPitch: settled,
                               settledDistance: map.camera.centerCoordinateDistance,
                               elapsed: Date().timeIntervalSince(start),
                               renderCallbacks: renderCount, mapErrors: errors,
                               status: classification)
                add(s)
            }
        }

        if !Task.isCancelled {
            showSwiftUI = true
            status = "SwiftUI Mapを初期化中"
            for _ in 0..<20 {
                if swiftUIReady || Task.isCancelled { break }
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { break }
            }
            if swiftUIReady && !Task.isCancelled {
                for d in distances {
                    if Task.isCancelled { break }
                    let start = Date()
                    let expectedPitch = 89.0
                    let value = MapCamera(centerCoordinate: center, distance: d,
                                          heading: targetHeading, pitch: expectedPitch)
                    let constructed = value.pitch
                    swiftUILatest = nil
                    swiftUIObservedAt = nil
                    status = "SwiftUI Map / \(Int(d)) m"
                    diag.log("PITCH_PROBE", "CONSTRUCTED", fields: [
                        "path": Path.swiftUI.rawValue, "requestedDistance": "\(d)",
                        "requestedPitch": "89",
                        "constructorPitch": "\(constructed)"
                    ])
                    swiftUICamera = value
                    swiftUIRevision += 1
                    do { try await Task.sleep(nanoseconds: 2_100_000_000) }
                    catch { break }
                    if Task.isCancelled { break }
                    let actual = swiftUILatest?.pitch
                    let classification = actual.map {
                        classify(expected: expectedPitch, actual: $0, errors: 0)
                    } ?? "no_swiftui_camera_callback"
                    let s = Sample(time: Date(), path: .swiftUI, requestedDistance: d,
                                   requestedPitch: expectedPitch, constructorPitch: constructed,
                                   immediatePitch: nil, renderPitch: nil,
                                   settledPitch: actual,
                                   settledDistance: swiftUILatest?.distance,
                                   elapsed: Date().timeIntervalSince(start),
                                   renderCallbacks: 0, mapErrors: 0, status: classification)
                    add(s)
                }
            } else {
                diag.log("PITCH_PROBE", "SWIFTUI_MAP_NOT_READY", level: "warning")
            }
        }

        let interrupted = Task.isCancelled || progress < total
        showSwiftUI = false
        // Recreating the UIKit map from the model restores the original camera.
        if let map = mkMap {
            map.setCamera(MKMapCamera(
                lookingAtCenter: center, fromDistance: model.requestedDistance,
                pitch: CGFloat(model.requestedPitch), heading: model.requestedHeading
            ), animated: false)
            switch model.mode {
            case .satelliteFlyover: map.mapType = .satelliteFlyover
            case .hybridFlyover: map.mapType = .hybridFlyover
            case .realisticImagery:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            }
        }
        isRunning = false
        status = interrupted ? "中断: \(progress)/\(total)件" : "比較完了: \(progress)/\(total)件"
        persistCSV()
        diag.log("PITCH_PROBE", interrupted ? "RUN_INTERRUPTED" : "RUN_FINISHED", fields: [
            "samples": "\(samples.count)", "total": "\(total)",
            "csv": csvURL?.lastPathComponent ?? "missing"
        ])
        work = nil
    }

    private func coordinate(from center: CLLocationCoordinate2D, distance: Double,
                            bearing: Double) -> CLLocationCoordinate2D {
        let radius = 6_371_000.0
        let delta = distance / radius
        let phi1 = center.latitude * .pi / 180
        let lambda1 = center.longitude * .pi / 180
        let azimuth = bearing * .pi / 180
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(azimuth))
        let lambda2 = lambda1 + atan2(sin(azimuth) * sin(delta) * cos(phi1),
                                      cos(delta) - sin(phi1) * sin(phi2))
        return CLLocationCoordinate2D(latitude: phi2 * 180 / .pi,
                                      longitude: lambda2 * 180 / .pi)
    }

    private func classify(expected: Double, actual: Double, errors: Int) -> String {
        if errors > 0 { return "mapkit_error" }
        return actual < expected - 1 ? "clamped" : "accepted"
    }

    private func add(_ sample: Sample) {
        samples.append(sample)
        progress = samples.count
        DiagnosticLogger.shared.log("PITCH_PROBE", "STEP_RESULT", fields: [
            "path": sample.path.rawValue,
            "requestedDistance": "\(sample.requestedDistance)",
            "requestedPitch": "\(sample.requestedPitch)",
            "constructorPitch": "\(sample.constructorPitch)",
            "afterApplyPitch": sample.immediatePitch.map { String($0) } ?? "not_available",
            "renderPitch": sample.renderPitch.map { String($0) } ?? "no_callback",
            "settledPitch": sample.settledPitch.map { String($0) } ?? "no_callback",
            "settledDistance": sample.settledDistance.map { String($0) } ?? "unknown",
            "renderCallbacks": "\(sample.renderCallbacks)",
            "mapkitErrors": "\(sample.mapErrors)",
            "status": sample.status
        ])
        persistCSV()
    }

    private func persistCSV() {
        let header = "time,path,requested_distance_m,requested_pitch_deg,constructor_pitch_deg,after_apply_pitch_deg,render_pitch_deg,settled_pitch_deg,settled_distance_m,elapsed_seconds,render_callbacks,mapkit_errors,status"
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = samples.map { s in
            [
                fmt.string(from: s.time), s.path.rawValue,
                format(s.requestedDistance), format(s.requestedPitch),
                format(s.constructorPitch), format(s.immediatePitch),
                format(s.renderPitch), format(s.settledPitch),
                format(s.settledDistance), format(s.elapsed),
                "\(s.renderCallbacks)", "\(s.mapErrors)", s.status
            ].map(escapeCSV).joined(separator: ",")
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlyoverPitchLab", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent("CameraConstraintProbe-latest.csv")
            try ([header] + rows).joined(separator: "\n").appending("\n")
                .write(to: dest, atomically: true, encoding: .utf8)
            csvURL = dest
        } catch {
            DiagnosticLogger.shared.log("PITCH_PROBE", "CSV_WRITE_FAILED",
                                        level: "error", fields: ["error": error.localizedDescription])
        }
    }

    private func format(_ d: Double?) -> String {
        d.map { String(format: "%.5f", $0) } ?? ""
    }
    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\"") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    func exportCSV() -> URL? {
        guard let csvURL, FileManager.default.fileExists(atPath: csvURL.path) else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Flyover-Camera-Pitch-Comparison.csv")
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: csvURL, to: temp)
            return temp
        } catch {
            DiagnosticLogger.shared.log("PITCH_PROBE", "CSV_EXPORT_FAILED",
                                        level: "error", fields: ["error": error.localizedDescription])
            return nil
        }
    }
}
