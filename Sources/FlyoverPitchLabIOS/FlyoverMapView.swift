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
        context.coordinator.setMode(model.mode, on: map)
        context.coordinator.applyCamera(model, to: map)
        context.coordinator.lastRevision = model.revision
        context.coordinator.lastMode = model.mode
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
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

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var model: MapModel?
        var lastMode: RenderMode?
        var lastRevision = -1

        init(model: MapModel) {
            self.model = model
        }

        func setMode(_ mode: RenderMode, on map: MKMapView) {
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
            map.setCamera(camera, animated: false)
            readCamera(map)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            readCamera(mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            readCamera(mapView)
        }

        private func readCamera(_ mapView: MKMapView) {
            let camera = mapView.camera
            let pitch = Double(camera.pitch)
            let distance = camera.centerCoordinateDistance
            let altitude = camera.altitude
            let heading = camera.heading
            let latitude = camera.centerCoordinate.latitude
            let longitude = camera.centerCoordinate.longitude
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
