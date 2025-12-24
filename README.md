# Heartbeat App

Heartbeat is a SwiftUI iOS application that plays loop-able rhythmic tracks and dynamically adjusts tempo based on the user's speed. It supports importing common audio formats (wav, mp3, aiff, m4a) and keeps playback running in the background.

## Features

- Modern SwiftUI UI with splash screen and home view
- Import audio loops and play them continuously
- Background audio playback
- Background location tracking with live speed
- Automatic tempo adjustment using device speed
- Modular, clean code structure

## Project Structure

```
HeartbeatApp/
  HeartbeatAppApp.swift
  Models/
    TempoCalculator.swift
  Services/
    AudioEngineManager.swift
    LocationManager.swift
  Views/
    RootView.swift
    SplashView.swift
    HomeView.swift
```

## Setup in Xcode

1. **Create a new Xcode project**
   - File → New → Project → iOS → App
   - Product Name: `HeartbeatApp`
   - Interface: `SwiftUI`
   - Language: `Swift`

2. **Add the source files**
   - Drag the `HeartbeatApp/` folder from this repo into the Xcode project.
   - Ensure “Copy items if needed” is checked.

3. **Configure Background Modes**
   - Select the app target → Signing & Capabilities → `+ Capability` → `Background Modes`
   - Enable:
     - `Audio, AirPlay, and Picture in Picture`
     - `Location updates`

4. **Add Privacy Usage Descriptions**
   - In `Info.plist`, add:
     - `NSLocationWhenInUseUsageDescription`: “We use your location to calculate live tempo.”
     - `NSLocationAlwaysAndWhenInUseUsageDescription`: “We use your location in the background to keep tempo in sync with speed.”
     - `NSLocationAlwaysUsageDescription`: “We use your location in the background to keep tempo in sync with speed.”

5. **Run on a real device**
   - Background audio and location updates require a physical device.
   - When prompted, allow **Always** location access.

## Notes

- The app uses `AVAudioEngine` with `AVAudioUnitTimePitch` to adjust playback speed while keeping pitch stable.
- Tempo is calculated as:
  ```
  newTempo = baseTempo + (speedMetersPerSecond * speedFactor)
  ```
- Base tempo defaults to **72 BPM** and can be changed in the Home view.

## Troubleshooting

- If audio won’t play in the background, confirm Background Modes are enabled and the device isn’t in Silent Mode.
- If speed stays at 0 m/s, test on a real device with outdoor GPS reception.

## License

MIT
