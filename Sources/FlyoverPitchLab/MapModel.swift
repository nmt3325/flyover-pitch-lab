import Combine
import CoreLocation
import Foundation

/// Switching map modes makes it easier to distinguish the legacy Flyover
/// renderer from the imagery + realistic-elevation renderer.
enum RenderMode: String, CaseIterable, Identifiable {
    case satelliteFlyover = "Satellite Flyover"
    case hybridFlyover = "Hybrid Flyover"
    case realisticImagery = "Realistic Imagery"

    var id: String { rawValue }
}

enum TestCity: String, CaseIterable, Identifiable {
    case tokyoTower = "Tokyo Tower"
    case shinjuku = "Shinjuku"
    case sanFrancisco = "San Francisco"
    case newYork = "New York"
    case custom = "Custom"

    var id: String { rawValue }

    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .tokyoTower: return .init(latitude: 35.6586, longitude: 139.7454)
        case .shinjuku: return .init(latitude: 35.6938, longitude: 139.7034)
        case .sanFrancisco: return .init(latitude: 37.7749, longitude: -122.4194)
        case .newYork: return .init(latitude: 40.7580, longitude: -73.9855)
        case .custom: return nil
        }
    }
}

/// The requested and observed camera values are intentionally independent.
/// In particular, do not claim 3DGS support from a pitch reading alone.
final class MapModel: ObservableObject {
    @Published var mode: RenderMode = .satelliteFlyover
    @Published var city: TestCity = .tokyoTower
    @Published var latitude: Double = 35.6586
    @Published var longitude: Double = 139.7454

    @Published var requestedPitch: Double = 85
    @Published var requestedDistance: Double = 1200
    @Published var requestedHeading: Double = 0

    @Published private(set) var actualPitch: Double? = nil
    @Published private(set) var actualDistance: Double? = nil
    @Published private(set) var actualAltitude: Double? = nil
    @Published private(set) var actualHeading: Double? = nil
    @Published private(set) var observedLatitude: Double? = nil
    @Published private(set) var observedLongitude: Double? = nil
    @Published private(set) var observedAt: Date? = nil
    @Published private(set) var revision: Int = 1

    func selectCity(_ value: TestCity) {
        city = value
        if let coordinate = value.coordinate {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
            apply()
        }
    }

    func apply() {
        latitude = min(max(latitude, -85), 85)
        longitude = min(max(longitude, -180), 180)
        requestedPitch = min(max(requestedPitch, 0), 90)
        requestedDistance = min(max(requestedDistance, 50), 30_000)
        requestedHeading = requestedHeading.truncatingRemainder(dividingBy: 360)
        revision += 1
    }

    func record(pitch: Double, distance: Double, altitude: Double,
                heading: Double, latitude: Double, longitude: Double) {
        guard pitch.isFinite, distance.isFinite, altitude.isFinite else { return }
        actualPitch = pitch
        actualDistance = distance
        actualAltitude = altitude
        actualHeading = heading
        observedLatitude = latitude
        observedLongitude = longitude
        observedAt = Date()
    }

    var clampDifference: Double? {
        guard let pitch = actualPitch else { return nil }
        return requestedPitch - pitch
    }
}
