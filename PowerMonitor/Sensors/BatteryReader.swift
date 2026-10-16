import Foundation
import IOKit
import IOKit.ps

// Reads the internal battery through IOKit power source APIs. Returns nil on Macs
// without a battery so the UI can show a placeholder instead of a fake value.
final class BatteryReader {
    func read() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else {
                continue
            }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
            // IOKit reports -1 while macOS is still estimating.
            let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (description[minutesKey] as? Int).flatMap { $0 >= 0 ? $0 : nil }
            let power = readPower(isPluggedIn: isPluggedIn)

            return BatteryStatus(
                percent: Double(current) / Double(max) * 100,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                isCharged: isCharged,
                minutesRemaining: minutes,
                negotiatedPower: power.negotiated,
                inputPower: power.input,
                batteryWatts: power.battery
            )
        }
        return nil
    }

    // The power-source API has no live wattage, so read the smart battery controller's
    // registry entry directly. Only the handful of keys we need are copied, since the
    // full property dictionary carries large calibration blobs.
    private func readPower(isPluggedIn: Bool) -> (negotiated: PowerReading?, input: PowerReading?, battery: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func number(_ value: Any?) -> Double? {
            (value as? NSNumber).map { Double($0.int64Value) }
        }

        // Registry values are in millivolts, milliamps and milliwatts.
        var battery: Double?
        if let millivolts = number(property("Voltage")), let milliamps = number(property("Amperage")) {
            battery = millivolts * milliamps / 1_000_000
        }

        // The adapter entries keep their last values after unplugging, so only trust them on AC.
        guard isPluggedIn else { return (nil, nil, battery) }

        var negotiated: PowerReading?
        if let adapter = property("AdapterDetails") as? [String: Any],
           let watts = number(adapter["Watts"]), watts > 0 {
            negotiated = PowerReading(
                watts: watts,
                volts: number(adapter["AdapterVoltage"]).map { $0 / 1000 },
                amps: number(adapter["Current"]).map { $0 / 1000 }
            )
        }

        // Apple Silicon only: measured power flowing in from the adapter.
        var input: PowerReading?
        if let telemetry = property("PowerTelemetryData") as? [String: Any],
           let milliwatts = number(telemetry["SystemPowerIn"]) {
            input = PowerReading(
                watts: milliwatts / 1000,
                volts: number(telemetry["SystemVoltageIn"]).map { $0 / 1000 },
                amps: number(telemetry["SystemCurrentIn"]).map { $0 / 1000 }
            )
        }

        return (negotiated, input, battery)
    }
}
