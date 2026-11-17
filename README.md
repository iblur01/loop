# Loop

[Français](README.fr.md)

Loop is an experimental iPhone app that brings health and activity data together in one place. Its long-term goal is to offer an experience comparable to Bevel, with support for a WHOOP band alongside other sources such as Apple Health.

Loop connects directly to a **WHOOP 4.0** over Bluetooth and combines its data with compatible information from Apple Health. Support for the **WHOOP 5.0 has not been tested** and is not guaranteed.

## What Loop does

- Collects data from a compatible band and brings it together with available Apple Health data.
- Presents daily metrics including sleep, recovery, strain, HRV and resting heart rate.
- Calculates metrics and personal baselines on the iPhone, using the data available over time.
- Keeps data locally and works offline, without a server or a WHOOP cloud connection.
- Offers optional manual backup and restore through the Files app.

Loop is designed as a personal project and remains a work in progress. Features and calculations may change as the app evolves.

## Beta and accuracy

**Loop is in beta.** A major focus is improving the calculation engine, especially sleep detection, recovery, strain and individual baselines. I wear an Apple Watch alongside the band to compare measurements and help identify inconsistencies.

These comparisons do not establish accuracy or equivalence with WHOOP or Apple Watch. Metrics are estimates, may be incomplete or incorrect, and are not medical advice.

## Origins and inspiration

Loop is a rework of the **my-whoop / OpenWhoop** proof of concept. It also draws inspiration from projects such as [Noop](https://github.com/app-noop/noop), and from the broader idea of apps like Bevel that bring health data together.

Loop is an independent project and is not affiliated with WHOOP, Noop or Bevel.

## Requirements

- An iPhone running **iOS 27 or later**.
- A WHOOP 4.0 band for band data. WHOOP 5.0 compatibility is untested.
- A Mac and a version of Xcode that supports iOS 27 to build the app.
- A physical iPhone for Bluetooth connectivity.

## Install with Xcode

1. Clone the repository and open `Loop.xcodeproj` in Xcode.
2. Under **Signing & Capabilities**, select your Apple team for the app and widget targets. Set unique bundle identifiers and a shared App Group for both targets as required by your account.
3. Connect your iPhone, select it as the run destination and run the **Loop** scheme. Enable Developer Mode on the iPhone if prompted.
4. Open Loop, grant the permissions you want to use and pair your band in the app.

If you change `project.yml` or add source files, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate` to regenerate the Xcode project.

With a free Apple Personal Team, the development signature generally expires after **7 days**, so you will need to rebuild or re-sign the app.

## Sign and sideload an IPA

You can also build or obtain an IPA, then sign and sideload it using your preferred method. I personally use UDID Registry to sign an IPA for around one year, typically for about €20. Prices, availability and certificate validity can vary.

## Screenshots

Screenshots will be added as the interface evolves.
