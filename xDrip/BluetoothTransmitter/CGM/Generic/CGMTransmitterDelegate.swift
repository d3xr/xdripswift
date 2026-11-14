import Foundation
import CoreBluetooth

/// Invalidates queued deliveries synchronously when a connection or CGM source changes.
final class CGMDeliveryGate {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stopped = false
    private var released = false
    func token() -> UInt64? { lock.lock(); defer { lock.unlock() }; return stopped ? nil : generation }
    func allows(_ token: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped && token == generation }
    func invalidate() { lock.lock(); generation &+= 1; lock.unlock() }
    func stop() { lock.lock(); stopped = true; generation &+= 1; lock.unlock() }
    func release() { lock.lock(); released = true; stopped = true; generation &+= 1; lock.unlock() }
    var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
}

/// to be implemented for anyone who needs to receive information from a specific type of cgm transmitter
protocol CGMTransmitterDelegate:AnyObject {
     
    /// only for transmitters that can detect new sensor
    /// - parameters:
    ///     - detected sensor start time, optional, default nil
    func newSensorDetected(sensorStartDate: Date?)
    
    /// only for transmitters that can detect an expired sensor - only used for Firefly (at the time of writing this), but could probably also be used for Libre
    func sensorStopDetected()
    
    /// only for transmitters that can detect missing sensor
    func sensorNotDetected()
    
    /// to pass back transmitter data from cgmtransmitter
    /// - parameters:
    ///     - glucoseData : array of RawGlucoseData, can be empty array, first entry is the youngest
    ///     - transmitterBatteryInfo : needed for battery level alarm
    ///     - sensorAge : only if transmitter can give that info, eg MiaoMiao, otherwise nil
    func cgmTransmitterInfoReceived(glucoseData:inout [GlucoseData], transmitterBatteryInfo:TransmitterBatteryInfo?, sensorAge: TimeInterval?)
    
    /// to pass some text error message, delegate can decide to show to user, log, ...
    func errorOccurred(xDripError: XdripError)

    /// Reports a decoded sensor/transmitter health state without promoting generic BLE errors.
    func sensorHealthEventOccurred(_ event: CGMSensorHealthEvent)

    /// Reports the decoded result of a sensor-start request.
    /// Dexcom G6/ONE provides this callback. The default implementation does nothing.
    func sensorSessionStartResultReceived(_ result: CGMSensorSessionStartResult)

    /// confirms that a validated glucose packet belongs to the matching local sensor session
    /// Dexcom G6/ONE provides this callback. The default implementation does nothing.
    func sensorSessionConfirmed(startDate: Date)

    /// An original session anchor corroborated by contiguous, current sensor history.
    /// This is metadata only; it does not imply that a glucose result is available.
    func sensorSessionObserved(startDate: Date, from transmitter: CGMTransmitter)

    /// A local session setting changed; this does not indicate new sensor communication.
    func sensorSessionConfigurationChanged(startDate: Date, from transmitter: CGMTransmitter)

    /// Reports G6/ONE calibration stages after reconciling the transmitter's session date.
    func dexcomG6CalibrationStateReceived(_ state: DexcomAlgorithmState, sensorStartDate: Date, from transmitter: CGMG5Transmitter)
    
}

extension CGMTransmitterDelegate {
    func sensorHealthEventOccurred(_ event: CGMSensorHealthEvent) {}
    func sensorSessionStartResultReceived(_ result: CGMSensorSessionStartResult) {}
    func sensorSessionConfirmed(startDate: Date) {}
    func sensorSessionObserved(startDate: Date, from transmitter: CGMTransmitter) {}
    func sensorSessionConfigurationChanged(startDate: Date, from transmitter: CGMTransmitter) {}
    func dexcomG6CalibrationStateReceived(_ state: DexcomAlgorithmState, sensorStartDate: Date, from transmitter: CGMG5Transmitter) {}
}
