import MapKit
import SwiftUI

/// Native UIKit MapKit viewer for iPhone and iPad.
/// Deliberately uses public APIs without Maps routing entitlements.
struct FlyoverMapView: UIViewRepresentable {
    @ObservedObject var model: MapModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.showsBuildings = true
        DiagnosticLogger.shared.log("MAPKIT", "MAP_VIEW_CREATED", fields: [
            "bounds": "\(map.bounds)",
            "pitchEnabled": "\(map.isPitchEnabled)",
            "rotateEnabled": "\(map.isRotateEnabled)"
        ])
        context.coordinator.setMode(model.mode, on: map)
        context.coordinator.applyCamera(model, to: map)
        context.coordinator.lastRevision = model.revision
        context.coordinator.lastMode = model.mode
        AutoDiagnosticController.shared.register(map)
        CameraConstraintProbe.shared.register(map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        if AutoDiagnosticController.shared.isRunning || CameraConstraintProbe.shared.isRunning { return }
        let coordinator = context.coordinator
        if coordinator.lastMode != model.mode {
            coordinator.setMode(model.mode, on: map)
            coordinator.lastMode = model.mode
            coordinator.applyCamera(model, to: map)
            coordinator.lastRevision = model.revision
        } else if coordinator.lastRevision != model.revision {
            coordinator.applyCamera(model, to: map)
            coordinator.lastRevision = model.revision
        }
        // Reading the observed camera must NOT continually reset the viewport.
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        AutoDiagnosticController.shared.unregister(uiView)
        CameraConstraintProbe.shared.unregister(uiView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let diagnostics = DiagnosticLogger.shared
        private var lastCameraLoggedAt = Date.distantPast
        private var lastCameraPublishedAt = Date.distantPast

        weak var model: MapModel?
        var lastMode: RenderMode?
        var lastRevision = -1

        init(model: MapModel) {
            self.model = model
        }

        func setMode(_ mode: RenderMode, on map: MKMapView) {
            diagnostics.log("MAPKIT", "SET_RENDER_MODE", fields: ["mode": mode.rawValue])
            switch mode {
            case .satelliteFlyover:
                map.mapType = .satelliteFlyover
            case .hybridFlyover:
                map.mapType = .hybridFlyover
            case .realisticImagery:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            }
        }

        func applyCamera(_ model: MapModel, to map: MKMapView) {
            let center = CLLocationCoordinate2D(latitude: model.latitude, longitude: model.longitude)
            let camera = MKMapCamera(
                lookingAtCenter: center,
                fromDistance: model.requestedDistance,
                pitch: CGFloat(model.requestedPitch),
                heading: model.requestedHeading
            )
            diagnostics.log("CAMERA", "CAMERA_REQUESTED", fields: [
                "latitude": "\(model.latitude)",
                "longitude": "\(model.longitude)",
                "pitch": "\(model.requestedPitch)",
                "distance": "\(model.requestedDistance)",
                "heading": "\(model.requestedHeading)",
                "renderMode": model.mode.rawValue
            ])
            map.setCamera(camera, animated: false)
            readCamera(map)
        }

        func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
            diagnostics.loadingStarted()
        }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            diagnostics.loadingFinished()
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            diagnostics.loadingFailed(error)
        }

        func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
            diagnostics.renderingStarted()
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            diagnostics.renderingFinished(completely: fullyRendered)
            CameraConstraintProbe.shared.noteMKRendering(mapView)
            readCamera(mapView, force: true)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            diagnostics.log("CAMERA", "REGION_WILL_CHANGE",
                fields: ["animated": "\(animated)"])
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            readCamera(mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            readCamera(mapView, force: true)
            diagnostics.log("CAMERA", "REGION_DID_CHANGE",
                fields: ["animated": "\(animated)"])
        }

        private func readCamera(_ mapView: MKMapView, force: Bool = false) {
            let now = Date()
            if !force && now.timeIntervalSince(lastCameraPublishedAt) < 0.25 {
                return
            }
            lastCameraPublishedAt = now
            let camera = mapView.camera
            let pitch = Double(camera.pitch)
            let distance = camera.centerCoordinateDistance
            let altitude = camera.altitude
            let heading = camera.heading
            let latitude = camera.centerCoordinate.latitude
            let longitude = camera.centerCoordinate.longitude
            if force || now.timeIntervalSince(lastCameraLoggedAt) >= 1 {
                lastCameraLoggedAt = now
                let requested = AutoDiagnosticController.shared.currentRequestedPitch ?? model?.requestedPitch ?? pitch
                diagnostics.log("CAMERA", "CAMERA_READBACK", fields: [
                    "pitch": "\(pitch)", "requestedPitch": "\(requested)",
                    "pitchDelta": "\(requested - pitch)",
                    "distance": "\(distance)", "altitude": "\(altitude)",
                    "heading": "\(heading)", "latitude": "\(latitude)",
                    "longitude": "\(longitude)"
                ])
            }
            // Avoid ObservableObject publishing while SwiftUI is updating a view.
            DispatchQueue.main.async { [weak self] in
                self?.model?.record(
                    pitch: pitch,
                    distance: distance,
                    altitude: altitude,
                    heading: heading,
                    latitude: latitude,
                    longitude: longitude
                )
            }
        }
    }
}
