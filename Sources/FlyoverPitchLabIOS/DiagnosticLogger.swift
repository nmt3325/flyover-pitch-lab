import Foundation
import Network
import OSLog
import SwiftUI
import UIKit

/// A best-effort, entirely on-device diagnostic recorder. MapKit's internal
/// tile requests, server response codes and account quotas are NOT public APIs.
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    @Published private(set) var recentLines: [String] = []
    @Published private(set) var eventCount = 0
    @Published private(set) var errorCount = 0
    @Published private(set) var loadCount = 0
    @Published private(set) var renderCount = 0
    @Published private(set) var fullyRendered: Bool? = nil
    @Published private(set) var networkState = "Checking network…"
    @Published private(set) var lastError = "None"

    private let session = UUID().uuidString
    private let start = Date()
    private let loggingDirectory: URL
    private let queue = DispatchQueue(label: "dev.nmt3325.flyoverpitchlab.networkmonitor")
    private let pathMonitor = NWPathMonitor()
    private let systemLogger = Logger(subsystem: "dev.nmt3325.flyoverpitchlab.ios", category: "MapKitDiagnostics")
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var waitingSince: Date?
    private var warnedAboutWait = false
    private var hadMapCallbacks = false
    private var warnedAboutNoCallbacks = false

    private var currentLog: URL { loggingDirectory.appendingPathComponent("diagnostics-current.jsonl") }
    private var priorLog: URL { loggingDirectory.appendingPathComponent("diagnostics-previous.jsonl") }
    private var olderLog: URL { loggingDirectory.appendingPathComponent("diagnostics-older.jsonl") }

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        loggingDirectory = documents.appendingPathComponent("FlyoverPitchLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: loggingDirectory, withIntermediateDirectories: true)

        log("APP", "SESSION_START", fields: [
            "session": session,
            "os": UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            "device": UIDevice.current.model,
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "host": "LiveContainer compatible; no special Maps entitlement",
            "lowPower": "\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
            "thermal": "\(ProcessInfo.processInfo.thermalState.rawValue)"
        ])

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status = path.status == .satisfied ? "satisfied" : "\(path.status)"
            let type: String
            if path.usesInterfaceType(.wifi) { type = "Wi-Fi" }
            else if path.usesInterfaceType(.cellular) { type = "Cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { type = "Ethernet" }
            else { type = "Other/none" }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let updated = "\(status), \(type), expensive=\(path.isExpensive), constrained=\(path.isConstrained)"
                guard self.networkState != updated else { return }
                self.networkState = updated
                self.log("NETWORK", "PATH_CHANGED", fields: [
                    "status": status, "interface": type,
                    "expensive": "\(path.isExpensive)",
                    "constrained": "\(path.isConstrained)"
                ])
            }
        }
        pathMonitor.start(queue: queue)

        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY_WARNING"),
            (UIApplication.didBecomeActiveNotification, "DID_BECOME_ACTIVE"),
            (UIApplication.willResignActiveNotification, "WILL_RESIGN_ACTIVE"),
            (UIApplication.didEnterBackgroundNotification, "DID_ENTER_BACKGROUND"),
            (UIApplication.willEnterForegroundNotification, "WILL_ENTER_FOREGROUND"),
            (ProcessInfo.powerStateDidChangeNotification, "POWER_STATE_CHANGED"),
            (ProcessInfo.thermalStateDidChangeNotification, "THERMAL_STATE_CHANGED")
        ]
        for (name, event) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.log("DEVICE", event, fields: [
                    "lowPower": "\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
                    "thermal": "\(ProcessInfo.processInfo.thermalState.rawValue)"
                ])
            }
            observers.append(token)
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkWatchdog()
        }
    }

    deinit {
        pathMonitor.cancel()
        watchdog?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func checkWatchdog() {
        if let since = waitingSince, Date().timeIntervalSince(since) > 25, !warnedAboutWait {
            warnedAboutWait = true
            log("WATCHDOG", "MAP_LOADING_OVER_25_SECONDS", level: "warning", fields: [
                "seconds": "\(Int(Date().timeIntervalSince(since)))",
                "note": "Slow or stalled loading, not evidence of quota enforcement"
            ])
        }
        if !hadMapCallbacks && !warnedAboutNoCallbacks && Date().timeIntervalSince(start) > 30 {
            warnedAboutNoCallbacks = true
            log("WATCHDOG", "NO_MAPKIT_LOADING_OR_RENDER_CALLBACKS", level: "warning", fields: [
                "note": "Could be cache, an idle view, or unsupported host behavior; not conclusive"
            ])
        }
    }

    func loadingStarted() {
        hadMapCallbacks = true
        waitingSince = Date()
        warnedAboutWait = false
        loadCount += 1
        log("MAPKIT", "WILL_START_LOADING_MAP", fields: ["loadSequence": "\(loadCount)"])
    }

    func loadingFinished() {
        hadMapCallbacks = true
        let elapsed = waitingSince.map { String(format: "%.3f", Date().timeIntervalSince($0)) } ?? "unknown"
        waitingSince = nil
        log("MAPKIT", "DID_FINISH_LOADING_MAP", fields: ["elapsedSeconds": elapsed])
    }

    func loadingFailed(_ error: Error) {
        hadMapCallbacks = true
        waitingSince = nil
        let e = error as NSError
        lastError = "\(e.domain) (\(e.code)): \(e.localizedDescription)"
        errorCount += 1
        var fields: [String: String] = [
            "domain": e.domain, "code": "\(e.code)",
            "description": e.localizedDescription
        ]
        if let cause = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlyingDomain"] = cause.domain
            fields["underlyingCode"] = "\(cause.code)"
            fields["underlyingDescription"] = cause.localizedDescription
        }
        // Don't copy arbitrary userInfo values: these can contain URLs or tokens.
        log("MAPKIT", "DID_FAIL_LOADING_MAP", level: "error", fields: fields)
    }

    func renderingStarted() {
        hadMapCallbacks = true
        log("MAPKIT", "WILL_START_RENDERING_MAP")
    }

    func renderingFinished(completely: Bool) {
        hadMapCallbacks = true
        fullyRendered = completely
        renderCount += 1
        log("MAPKIT", "DID_FINISH_RENDERING_MAP",
            level: completely ? "info" : "warning",
            fields: [
                "fullyRendered": "\(completely)",
                "sequence": "\(renderCount)",
                "note": completely ? "Visible tiles completed; does not prove 3DGS" :
                    "Some visible tiles could not render; does not establish an account quota"
            ])
    }

    func log(_ category: String, _ event: String,
             level: String = "info", fields: [String: String] = [:]) {
        // Call from the UI thread; monitor updates are dispatched to main.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let record: [String: Any] = [
            "time": timestamp, "uptimeSeconds": Double(String(format: "%.3f", Date().timeIntervalSince(start))) ?? 0,
            "session": session, "level": level, "category": category,
            "event": event, "details": fields
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }

        // 3 x 4 MiB rolling JSONL files, retained across app restarts.
        rotateIfNecessary(incomingBytes: data.count + 1)
        if !FileManager.default.fileExists(atPath: currentLog.path) {
            FileManager.default.createFile(atPath: currentLog.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: currentLog) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([10]))
            } catch {
                // OSLog still records the event if the guest sandbox is unwritable.
                systemLogger.error("Cannot persist diagnostics: \(error.localizedDescription, privacy: .public)")
            }
        }
        if level == "error" { systemLogger.error("\(line, privacy: .public)") }
        else if level == "warning" { systemLogger.warning("\(line, privacy: .public)") }
        else { systemLogger.info("\(line, privacy: .public)") }

        eventCount += 1
        recentLines.append("[\(timestamp)] \(level.uppercased()) \(category).\(event) \(fields)")
        if recentLines.count > 180 {
            recentLines.removeFirst(recentLines.count - 180)
        }
    }

    private func rotateIfNecessary(incomingBytes: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: currentLog.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size + incomingBytes > 4 * 1024 * 1024 else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: olderLog)
        if fm.fileExists(atPath: priorLog.path) {
            try? fm.moveItem(at: priorLog, to: olderLog)
        }
        if fm.fileExists(atPath: currentLog.path) {
            try? fm.moveItem(at: currentLog, to: priorLog)
        }
    }

    func copyableText() -> String {
        recentLines.joined(separator: "\n")
    }

    func exportLog() -> URL? {
        let files = [olderLog, priorLog, currentLog]
        var combined = Data()
        for file in files {
            if let data = try? Data(contentsOf: file) {
                combined.append(data)
            }
        }
        guard !combined.isEmpty else { return nil }
        let exportDirectory = FileManager.default.temporaryDirectory
        let url = exportDirectory.appendingPathComponent("FlyoverPitchLab-Diagnostics-\(session.prefix(8)).jsonl")
        do {
            try combined.write(to: url, options: .atomic)
            log("APP", "EXPORTED_LOG", fields: [
                "fileBytes": "\(combined.count)", "filename": url.lastPathComponent
            ])
            return url
        } catch {
            log("APP", "EXPORT_FAILED", level: "error", fields: ["description": error.localizedDescription])
            return nil
        }
    }

    func clearLog() {
        for file in [olderLog, priorLog, currentLog] {
            try? FileManager.default.removeItem(at: file)
        }
        recentLines.removeAll()
        eventCount = 0
        errorCount = 0
        loadCount = 0
        renderCount = 0
        fullyRendered = nil
        lastError = "None"
        log("APP", "LOG_CLEARED")
    }
}
