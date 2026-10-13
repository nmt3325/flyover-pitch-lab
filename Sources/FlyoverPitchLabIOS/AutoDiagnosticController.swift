import Foundation
import MapKit
import SwiftUI
import UIKit

/// Serial, cancellable camera sweep. Public MapKit callbacks and camera
/// readback are observations; they do NOT expose Apple's tile HTTP status,
/// server-side rate limits, or Enhanced Flyover / 3DGS support.
@MainActor
final class AutoDiagnosticController: ObservableObject {
    static let shared = AutoDiagnosticController()

    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let mode: RenderMode
        let distance: Double
        let requestedPitch: Double
        let actualPitch: Double
        let actualDistance: Double
        let altitude: Double
        let heading: Double
        let elapsed: Double
        let loadEvents: Int
        let renderEvents: Int
        let fullyRendered: String
        let errorEvents: Int
        let result: String
    }

    struct GroupResult: Identifiable {
        var id: String { "\(mode.rawValue)-\(Int(distance))" }
        let mode: RenderMode
        let distance: Double
        let maxObserved: Double
        let at89: Double?
        let trials: Int
    }

    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0
    @Published private(set) var totalSteps = 0
    @Published private(set) var status = "未実行"
    @Published private(set) var currentMode: RenderMode?
    @Published private(set) var currentDistance: Double?
    @Published private(set) var currentRequestedPitch: Double?
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var lastCSVURL: URL?

    /// Each distance is tested at 60°, 75° and 89°.
    /// 89° readback estimates the maximum achievable pitch *at this location*.
    private let distances: [Double] = [50, 200, 500, 1200, 3000, 10000]
    private let pitches: [Double] = [60, 75, 89]
    private weak var mapView: MKMapView?
    private var task: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        // A LiveContainer guest may be terminated mid-sweep. Keep any CSV
        // written by prior measurements available for export after relaunch.
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlyoverPitchLab", isDirectory: true)
        let saved = folder.appendingPathComponent("AutoDiagnostic-latest.csv")
        if FileManager.default.fileExists(atPath: saved.path) {
            lastCSVURL = saved
            status = "保存済みの診断CSVがあります（前回分）"
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isRunning == true { self?.cancel(reason: "バックグラウンドに移動") }
            }
        }
    }

    func register(_ map: MKMapView) {
        mapView = map
    }

    func unregister(_ map: MKMapView) {
        if mapView === map {
            mapView = nil
            if isRunning { cancel(reason: "マップビューが破棄されました") }
        }
    }

    func start(model: MapModel) {
        guard !isRunning else { return }
        guard let map = mapView else {
            status = "MapKitのビューがありません"
            DiagnosticLogger.shared.log("AUTOTEST", "START_FAILED", level: "error",
                                        fields: ["reason": "MapKit view missing"])
            return
        }
        let lat = model.latitude
        let lon = model.longitude
        guard lat.isFinite && lon.isFinite &&
              (-85...85).contains(lat) && (-180...180).contains(lon) else {
            status = "緯度経度を確認してください"
            return
        }
        isRunning = true
        progress = 0
        totalSteps = RenderMode.allCases.count * distances.count * pitches.count
        currentMode = nil
        currentDistance = nil
        currentRequestedPitch = nil
        lastCSVURL = nil
        samples = []
        status = "自動測定を開始しました"
        let heading = model.requestedHeading.isFinite ? model.requestedHeading : 0
        DiagnosticLogger.shared.log("AUTOTEST", "SWEEP_STARTED", fields: [
            "latitude": "\(lat)", "longitude": "\(lon)", "heading": "\(heading)",
            "distances": distances.map { String(Int($0)) }.joined(separator: ","),
            "pitches": pitches.map { String(Int($0)) }.joined(separator: ","),
            "modes": RenderMode.allCases.map(\.rawValue).joined(separator: ","),
            "totalSteps": "\(totalSteps)",
            "note": "Readbacks measure camera clamping; no server quota data"
        ])
        task = Task { [weak self, weak model, weak map] in
            guard let self, let model else { return }
            await self.run(model: model, map: map, latitude: lat,
                           longitude: lon, heading: heading)
        }
    }

    func cancel(reason: String = "ユーザーが中断") {
        guard isRunning else { return }
        status = "\(reason) — 停止処理中"
        task?.cancel()
        DiagnosticLogger.shared.log("AUTOTEST", "STOP_REQUESTED",
                                    fields: ["reason": reason, "completed": "\(progress)"])
    }

    var groupResults: [GroupResult] {
        RenderMode.allCases.flatMap { mode in
            distances.compactMap { distance -> GroupResult? in
                let matching = samples.filter {
                    $0.mode == mode && $0.distance == distance
                }
                guard let maximum = matching.map(\.actualPitch).max() else { return nil }
                return GroupResult(
                    mode: mode, distance: distance, maxObserved: maximum,
                    at89: matching.first(where: { $0.requestedPitch == 89 })?.actualPitch,
                    trials: matching.count
                )
            }
        }
    }

    private func selectMode(_ mode: RenderMode, on map: MKMapView) {
        switch mode {
        case .satelliteFlyover:
            map.mapType = .satelliteFlyover
        case .hybridFlyover:
            map.mapType = .hybridFlyover
        case .realisticImagery:
            map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        }
        DiagnosticLogger.shared.log("AUTOTEST", "MODE_SELECTED",
                                    fields: ["mode": mode.rawValue])
    }

    private func run(model: MapModel, map initialMap: MKMapView?,
                     latitude: Double, longitude: Double, heading: Double) async {
        let diag = DiagnosticLogger.shared
        for mode in RenderMode.allCases {
            if Task.isCancelled || mapView == nil { break }
            guard let map = mapView else { break }
            selectMode(mode, on: map)
            for distance in distances {
                if Task.isCancelled || mapView == nil { break }
                for pitch in pitches {
                    if Task.isCancelled || mapView == nil { break }
                    currentMode = mode
                    currentDistance = distance
                    currentRequestedPitch = pitch
                    status = "\(mode.rawValue) · \(Int(distance)) m · \(Int(pitch))°"
                    let startTime = Date()
                    let priorErrors = diag.errorCount
                    let priorLoads = diag.loadCount
                    let priorRenders = diag.renderCount
                    let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    let camera = MKMapCamera(
                        lookingAtCenter: center,
                        fromDistance: distance,
                        pitch: CGFloat(pitch),
                        heading: heading
                    )
                    diag.log("AUTOTEST", "STEP_REQUESTED", fields: [
                        "step": "\(progress + 1)", "total": "\(totalSteps)",
                        "mode": mode.rawValue, "distance": "\(distance)",
                        "requestedPitch": "\(pitch)", "heading": "\(heading)"
                    ])
                    map.setCamera(camera, animated: false)

                    // Allow MapKit to apply its own camera constraints and process
                    // region/render events. Cached tiles may produce no callbacks.
                    do {
                        try await Task.sleep(nanoseconds: 1_300_000_000)
                        if diag.loadCount > priorLoads && diag.renderCount == priorRenders {
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    } catch { break }
                    if Task.isCancelled { break }

                    let actual = map.camera
                    let renderEvents = max(0, diag.renderCount - priorRenders)
                    let errorEvents = max(0, diag.errorCount - priorErrors)
                    let completed = renderEvents == 0 ? "unknown" :
                                    (diag.fullyRendered == true ? "true" : "false")
                    let pitchActual = Double(actual.pitch)
                    let classification: String
                    if errorEvents > 0 { classification = "mapkit_error" }
                    else if completed == "false" { classification = "incomplete_render" }
                    else if pitch - pitchActual > 1 { classification = "pitch_clamped" }
                    else { classification = "pitch_accepted" }
                    let entry = Sample(
                        time: Date(), mode: mode, distance: distance,
                        requestedPitch: pitch, actualPitch: pitchActual,
                        actualDistance: actual.centerCoordinateDistance,
                        altitude: actual.altitude, heading: actual.heading,
                        elapsed: Date().timeIntervalSince(startTime),
                        loadEvents: max(0, diag.loadCount - priorLoads),
                        renderEvents: renderEvents, fullyRendered: completed,
                        errorEvents: errorEvents, result: classification
                    )
                    samples.append(entry)
                    progress = samples.count
                    let fields: [String: String] = [
                        "step": "\(progress)", "mode": mode.rawValue,
                        "requestedDistance": "\(distance)",
                        "requestedPitch": "\(pitch)",
                        "actualPitch": "\(entry.actualPitch)",
                        "pitchDifference": "\(pitch - entry.actualPitch)",
                        "actualDistance": "\(entry.actualDistance)",
                        "actualAltitude": "\(entry.altitude)",
                        "elapsedSeconds": String(format: "%.3f", entry.elapsed),
                        "loadEvents": "\(entry.loadEvents)",
                        "renderEvents": "\(entry.renderEvents)",
                        "fullyRendered": completed,
                        "errorEvents": "\(errorEvents)",
                        "result": classification
                    ]
                    diag.log("AUTOTEST", "STEP_RESULT",
                             level: errorEvents > 0 ? "warning" : "info", fields: fields)
                    persistCSV()
                }
            }
        }

        // Avoid leaving the app in the test mode/angle.
        if let map = mapView {
            selectMode(model.mode, on: map)
            map.setCamera(
                MKMapCamera(
                    lookingAtCenter: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    fromDistance: model.requestedDistance,
                    pitch: CGFloat(model.requestedPitch), heading: model.requestedHeading
                ), animated: false
            )
        }
        let interrupted = Task.isCancelled || progress < totalSteps
        isRunning = false
        currentMode = nil
        currentDistance = nil
        currentRequestedPitch = nil
        task = nil
        status = interrupted ? "中断：\(progress)/\(totalSteps) 件を記録" :
                               "完了：\(progress) 件を記録しました"
        persistCSV()
        diag.log("AUTOTEST", interrupted ? "SWEEP_INTERRUPTED" : "SWEEP_FINISHED",
                 fields: ["completedSteps": "\(progress)",
                          "totalSteps": "\(totalSteps)",
                          "groups": "\(groupResults.count)",
                          "resultsCSV": lastCSVURL?.lastPathComponent ?? "unavailable"])
    }

    /// CSV is written after every successful step: incomplete runs survive
    /// crashes and LiveContainer guest termination.
    private func persistCSV() {
        let header = "time,mode,requested_distance_m,requested_pitch_deg,actual_pitch_deg,pitch_difference_deg,actual_distance_m,altitude_m,heading_deg,elapsed_seconds,load_events,render_events,fully_rendered,mapkit_errors,classification"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = samples.map { sample in
            [
                formatter.string(from: sample.time),
                sample.mode.rawValue,
                number(sample.distance), number(sample.requestedPitch),
                number(sample.actualPitch),
                number(sample.requestedPitch - sample.actualPitch),
                number(sample.actualDistance), number(sample.altitude),
                number(sample.heading), number(sample.elapsed),
                "\(sample.loadEvents)", "\(sample.renderEvents)",
                sample.fullyRendered, "\(sample.errorEvents)", sample.result
            ].map(csvEscape).joined(separator: ",")
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlyoverPitchLab", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("AutoDiagnostic-latest.csv")
            try ([header] + rows).joined(separator: "\n").appending("\n")
                .write(to: file, atomically: true, encoding: .utf8)
            lastCSVURL = file
        } catch {
            DiagnosticLogger.shared.log("AUTOTEST", "CSV_SAVE_FAILED", level: "error",
                                        fields: ["error": error.localizedDescription])
        }
    }

    private func number(_ x: Double) -> String { String(format: "%.5f", x) }
    private func csvEscape(_ x: String) -> String {
        if x.contains(",") || x.contains("\"") || x.contains("\n") {
            return "\"" + x.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return x
    }

    func exportCSV() -> URL? {
        guard let file = lastCSVURL, FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        let export = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlyoverPitchLab-AutoDiagnostic.csv")
        do {
            try? FileManager.default.removeItem(at: export)
            try FileManager.default.copyItem(at: file, to: export)
            return export
        } catch {
            DiagnosticLogger.shared.log("AUTOTEST", "CSV_EXPORT_FAILED", level: "error",
                                        fields: ["error": error.localizedDescription])
            return nil
        }
    }
}
