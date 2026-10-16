import Foundation
import IOKit
import IOKit.ps

// Reads the internal battery through IOKit power source APIs. Returns nil on Macs
// without a battery so the UI can show a placeholder instead of a fake value.
final class BatteryReader {
    private let smc = SMCConnection()

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

            return BatteryStatus(
                percent: Double(current) / Double(max) * 100,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                isCharged: isCharged,
                minutesRemaining: minutes,
                negotiatedPower: isPluggedIn ? readNegotiatedPower() : nil,
                inputPower: isPluggedIn ? readInputPower() : nil,
                batteryWatts: readBatteryWatts(isPluggedIn: isPluggedIn)
            )
        }
        return nil
    }

    // powerd refreshes the adapter details as soon as a charger attaches.
    private func readNegotiatedPower() -> PowerReading? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = number(details[kIOPSPowerAdapterWattsKey]), watts > 0 else {
            return nil
        }
        // Voltage and current are reported in millivolts and milliamps.
        return PowerReading(
            watts: watts,
            volts: number(details["AdapterVoltage"]).map { $0 / 1000 },
            amps: number(details[kIOPSPowerAdapterCurrentKey]).map { $0 / 1000 }
        )
    }

    // The SMC DC-in sensors update every second. AppleSmartBattery telemetry only
    // refreshes about once a minute, so it is just a fallback for Macs without them.
    private func readInputPower() -> PowerReading? {
        if let watts = smc.readNumericValue("PDTR") {
            return PowerReading(watts: watts, volts: smc.readNumericValue("VD0R"), amps: smc.readNumericValue("ID0R"))
        }
        guard let telemetry = smartBatteryProperty("PowerTelemetryData") as? [String: Any],
              let milliwatts = number(telemetry["SystemPowerIn"]) else {
            return nil
        }
        return PowerReading(
            watts: milliwatts / 1000,
            volts: number(telemetry["SystemVoltageIn"]).map { $0 / 1000 },
            amps: number(telemetry["SystemCurrentIn"]).map { $0 / 1000 }
        )
    }

    // Positive while charging, negative while discharging.
    private func readBatteryWatts(isPluggedIn: Bool) -> Double? {
        if let millivolts = smcInteger("B0AV"), (3_000...30_000).contains(millivolts),
           let milliamps = smcInteger("B0AC") {
            return millivolts * milliamps / 1_000_000
        }

        guard let millivolts = number(smartBatteryProperty("Voltage")),
              let milliamps = number(smartBatteryProperty("Amperage")) else {
            return nil
        }
        let watts = millivolts * milliamps / 1_000_000
        // Right after unplugging, the registry still holds the last charging current.
        if !isPluggedIn && watts > 0 {
            return nil
        }
        return watts
    }

    // Battery integers are little-endian on Apple Silicon and big-endian on Intel,
    // while SMCConnection's integer decoding assumes the Intel layout.
    private func smcInteger(_ key: String) -> Double? {
        guard let value = smc.readValue(key), value.bytes.count >= 2 else { return nil }
        #if arch(arm64)
        let raw = UInt16(value.bytes[0]) | UInt16(value.bytes[1]) << 8
        #else
        let raw = UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])
        #endif
        switch value.dataType {
        case "si16":
            return Double(Int16(bitPattern: raw))
        case "ui16":
            return Double(raw)
        default:
            return nil
        }
    }

    private func smartBatteryProperty(_ key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // Registry numbers are 64-bit; negative values only survive through int64Value.
    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber).map { Double($0.int64Value) }
    }
}
