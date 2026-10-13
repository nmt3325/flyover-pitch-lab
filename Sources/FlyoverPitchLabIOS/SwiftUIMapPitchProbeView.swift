import MapKit
import SwiftUI

/// A separate SwiftUI Map instance, not an MKMapView wrapper.
/// onMapCameraChange reports the camera exposed by SwiftUI; this API
/// does not provide a per-tile rendering callback or HTTP quota status.
struct SwiftUIMapPitchProbeView: View {
    @ObservedObject private var probe = CameraConstraintProbe.shared
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position)
            .mapStyle(.imagery(elevation: .realistic))
            .onAppear {
                probe.markSwiftUIReady()
                if let camera = probe.swiftUICamera {
                    position = .camera(camera)
                    probe.swiftUIPositionApplied(position)
                }
            }
            .onChange(of: probe.swiftUIRevision) { _, _ in
                if let camera = probe.swiftUICamera {
                    position = .camera(camera)
                    probe.swiftUIPositionApplied(position)
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                probe.observeSwiftUI(context.camera)
            }
    }
}
