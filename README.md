# Flyover Pitch Lab

> **iPhone / iPad (iOS & iPadOS 27):** The unsigned IPA is now built automatically on GitHub Actions. **[Download the iOS/iPadOS artifact](https://github.com/nmt3325/flyover-pitch-lab/actions/workflows/ios-ipa.yml)** and see **[LiveContainer installation and iOS usage](README-iOS.md)**. No Apple Developer paid account, Maps routing entitlement, or provisioning profile is required to compile. The guest is not yet physical-device tested.

A tiny **native macOS MapKit viewer** for testing whether Apple Maps Flyover allows near-horizontal (pitch 85–90°) camera angles and whether the imagery looks like the latest Enhanced Flyover/3DGS experience.

**This does not extract Apple Maps geometry and does not claim that MapKit exposes the new 3DGS data.** It deliberately compares *requested* versus *read-back* camera values.

## Features

- Three MapKit rendering modes: **Satellite Flyover**, **Hybrid Flyover**, **Realistic Imagery**.
- Camera pitch slider **0–90°**, one-click **89°** preset, distance **50–10,000 m**, heading **0–359°**.
- View the **actual camera pitch, distance, altitude, and heading** read from `MKMapView.camera` and detect likely clamping.
- Map controls via mouse/trackpad; presets for **Tokyo Tower**, **Shinjuku**, **San Francisco**, and **New York**, plus manual coordinates.
- GitHub Actions builds **Apple Silicon with Xcode 27** and **Intel with Xcode 26**, produces ZIP-packed `.app` bundles.
- No third-party runtime dependencies and no MapKit JS/API token.

## Downloading from GitHub Actions

1. Open the repository's **Actions → Build macOS app** workflow.
2. Open a successful run and scroll to **Artifacts**.
3. Download `FlyoverPitchLab-arm64-xcode27` for Apple Silicon (M-series) or `FlyoverPitchLab-x86_64-xcode26` for Intel.
4. Unzip and move `FlyoverPitchLab.app` to Applications. It is **ad-hoc signed**, not Apple-notarized, so macOS Gatekeeper may block first launch. Open via **right-click → Open** / **Privacy & Security → Open Anyway**, if you trust the source.

Note: Only the Apple Silicon build uses Xcode 27. Running macOS 27 is suggested for testing Apple's latest imagery. The build itself does not need an Apple Developer account.

## Local build

Requires a Mac with Xcode installed:

```sh
bash scripts/bundle-app.sh local
open dist/FlyoverPitchLab.app
```

The project is a standalone Swift Package (`Package.swift`), so you can open it with Xcode directly.

## Suggested experiment

1. On macOS 27, open **Apple Maps** at Tokyo Tower (35.6586, 139.7454). Enable the newest aerial 3D scene; take a screenshot.
2. Launch **Flyover Pitch Lab** at the same preset and use `Satellite Flyover` first.
3. Set pitch to 60°, 75°, 85°, 89° and click **Apply camera** after each change. Watch the **actual pitch readback** — Apple may limit pitch based on distance/altitude.
4. Try distance 200, 500, 1200, 3000 m. Compare `Satellite Flyover` to `Realistic Imagery`.
5. Compare tree canopies, façades, thin structures, and view-dependent detail against Apple Maps.

### Interpreting results

- If actual pitch is consistently less than requested, MapKit probably **clamped the camera**; 90° is not necessarily possible.
- If the actual pitch is accepted, this confirms the **camera setting**, **not** the underlying 3D representation.
- Same-looking imagery is suggestive of a shared rendering path but **does not prove 3DGS**. Differences may be caused by region availability, caching, app settings, or OS version.
- `MKMapCamera.pitch` is documented to have no fixed maximum: it depends on altitude.

## Notes

- Apple Maps imagery and Flyover coverage vary by city.
- `Realistic Imagery` is `MKImageryMapConfiguration(elevationStyle: .realistic)`, **not** a guaranteed "Enhanced Flyover" selector.
- This demo does not use private APIs, capture network data, or export Apple Maps assets.

## License

MIT. Apple Maps / MapKit usage remains subject to Apple's terms.

## Publish the repository yourself (if GitHub MCP cannot create repos)

Unzip the source on your Mac and run the following in the folder with `Package.swift`:

```sh
gh auth login
bash scripts/publish.sh
```

This creates **public** repository `nmt3325/flyover-pitch-lab`, pushes `main`, and automatically triggers the GitHub Actions build. If a repository of that name already exists, choose an alternate name in the script.
