import MapKit
import SwiftUI

/// Native MKMapView: not a browser or a captured Apple Maps screenshot.
struct FlyoverMapView: NSViewRepresentable {
    @ObservedObject var model: MapModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.showsBuildings = true
        context.coordinator.applyConfiguration(to: map, mode: model.mode)
        context.coordinator.applyRequestedCamera(to: map, model: model)
        context.coordinator.lastRevision = model.revision
        context.coordinator.lastMode = model.mode
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastMode != model.mode {
            coordinator.applyConfiguration(to: map, mode: model.mode)
            coordinator.lastMode = model.mode
            coordinator.applyRequestedCamera(to: map, model: model)
            coordinator.lastRevision = model.revision
        } else if coordinator.lastRevision != model.revision {
            coordinator.applyRequestedCamera(to: map, model: model)
            coordinator.lastRevision = model.revision
        }
        // Observed readings update the SwiftUI UI without re-applying the camera.
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var model: MapModel?
        var lastRevision = -1
        var lastMode: RenderMode?

        init(model: MapModel) {
            self.model = model
        }

        func applyConfiguration(to map: MKMapView, mode: RenderMode) {
            switch mode {
            case .satelliteFlyover:
                map.mapType = .satelliteFlyover
            case .hybridFlyover:
                map.mapType = .hybridFlyover
            case .realisticImagery:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            }
        }

        func applyRequestedCamera(to map: MKMapView, model: MapModel) {
            let coordinate = CLLocationCoordinate2D(
                latitude: model.latitude, longitude: model.longitude
            )
            let camera = MKMapCamera(
                lookingAtCenter: coordinate,
                fromDistance: model.requestedDistance,
                pitch: CGFloat(model.requestedPitch),
                heading: model.requestedHeading
            )
            map.setCamera(camera, animated: false)
            captureCamera(from: map)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            captureCamera(from: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            captureCamera(from: mapView)
        }

        private func captureCamera(from map: MKMapView) {
            let camera = map.camera
            let pitch = Double(camera.pitch)
            let distance = camera.centerCoordinateDistance
            let altitude = camera.altitude
            let heading = camera.heading
            let latitude = camera.centerCoordinate.latitude
            let longitude = camera.centerCoordinate.longitude
            // MapKit delegates may fire during NSViewRepresentable updates. Defer
            // publishing to avoid "Publishing changes from within view updates".
            DispatchQueue.main.async { [weak self] in
                self?.model?.record(pitch: pitch, distance: distance,
                                    altitude: altitude, heading: heading,
                                    latitude: latitude, longitude: longitude)
            }
        }
    }
}
