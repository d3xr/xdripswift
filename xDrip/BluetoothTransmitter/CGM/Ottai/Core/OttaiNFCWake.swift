// SPDX-License-Identifier: GPL-3.0-or-later
// Passive RF-field wake for Ottai CN / Syai.
// Source contract: ctqvva/JugglucoNG@91fed63ffb83b5b002186a8574b4af696c3839f9
// Common/src/main/java/tk/glucodata/drivers/ottai/OttaiNfc.kt (RF-field wake).
// https://github.com/ctqvva/JugglucoNG/blob/91fed63ffb83b5b002186a8574b4af696c3839f9/Common/src/main/java/tk/glucodata/drivers/ottai/OttaiNfc.kt
// This reader never connects to a tag and never reads or writes tag application data.

import Foundation
import UIKit
@preconcurrency import CoreNFC

protocol OttaiNFCWakeReader: AnyObject {
    func begin()
    func invalidate()
}

/// Main-queue owner of one manually requested RF-field session. Reader readiness and
/// tag detection are observations, not proof of sensor identity, wake or activation.
final class OttaiNFCWake {
    enum Invalidation: Equatable { case cancelled, timedOut, failed(String) }
    enum Event: Equatable { case readerReady, tagDetected, invalidated(Invalidation) }
    enum Outcome: Equatable {
        case tagObserved, cancelled, timedOut, ownerChanged, notRequired, busy, unavailable(String), failed(String)

        var message: String {
            switch self {
            case .tagObserved:
                return "An NFC tag was detected. Its identity and the sensor wake are not verified. Check Bluetooth, select the sensor and use Start / activate sensor."
            case .cancelled:
                return "The NFC session was closed. Sensor wake is not confirmed. Check Bluetooth before using Start / activate sensor."
            case .timedOut:
                return "The NFC session timed out. Sensor wake is not confirmed. Check Bluetooth, or retry the NFC field near the sensor."
            case .ownerChanged:
                return "The selected sensor, account or screen changed. The NFC session was closed without confirming a wake."
            case .notRequired:
                return "Global Ottai does not require this CN/Syai NFC wake. Connect over Bluetooth, then use Start / activate sensor."
            case .busy: return "An NFC wake session is already open. Close it before starting another."
            case .unavailable(let reason), .failed(let reason): return reason
            }
        }
    }

    typealias MakeReader = (@escaping (Event) -> Void) -> OttaiNFCWakeReader?
    private let enabled: Bool
    private let hardwareAvailable: () -> Bool
    private let isForeground: () -> Bool
    private let makeReader: MakeReader
    private let scheduleTimeout: (@escaping () -> Void) -> Void
    private let notifications: NotificationCenter
    private var backgroundObserver: NSObjectProtocol?
    private var attemptID: UUID?
    private var reader: OttaiNFCWakeReader?
    private var isOwnerCurrent: (() -> Bool)?
    private var onReady: (() -> Void)?
    private var completion: ((Outcome) -> Void)?

    static func requiresWake(apiBase: String) -> Bool {
        apiBase == OttaiConstants.apiBase || apiBase == OttaiConstants.apiBaseSyai
    }

    /// Info.plist build variables are strings; both explicit Bool and YES/true work.
    /// Missing/unexpanded values default to disabled before any reader is created.
    static func signingCapability(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        guard let text = value as? String else { return false }
        return ["yes", "true", "1"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static var enabledInThisBuild: Bool {
        signingCapability(Bundle.main.object(forInfoDictionaryKey: "OttaiNFCWakeEnabled"))
    }

    init(enabled: Bool = OttaiNFCWake.enabledInThisBuild,
         hardwareAvailable: @escaping () -> Bool = { NFCTagReaderSession.readingAvailable },
         isForeground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         notifications: NotificationCenter = .default,
         scheduleTimeout: @escaping (@escaping () -> Void) -> Void = { block in DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: block) },
         makeReader: MakeReader? = nil) {
        self.enabled = enabled
        self.hardwareAvailable = hardwareAvailable
        self.isForeground = isForeground
        self.notifications = notifications
        self.scheduleTimeout = scheduleTimeout
        self.makeReader = makeReader ?? { CoreNFCOttaiWakeReader(event: $0) }
    }

    deinit {
        if let backgroundObserver { notifications.removeObserver(backgroundObserver) }
        reader?.invalidate()
    }

    func start(apiBase: String, isOwnerCurrent: @escaping () -> Bool,
               onReaderReady: @escaping () -> Void = {}, completion: @escaping (Outcome) -> Void) {
        precondition(Thread.isMainThread)
        guard attemptID == nil else { completion(.busy); return }
        guard Self.requiresWake(apiBase: apiBase) else { completion(.notRequired); return }
        guard enabled else {
            completion(.unavailable("This build is signed without NFC wake capability. Ottai CN / Syai wake requires an NFC-enabled provisioning profile and entitlement. No NFC session was started. Global Ottai uses Bluetooth without this step.")); return
        }
        guard isForeground() else { completion(.unavailable("Open xDrip in the foreground before starting NFC wake.")); return }
        guard isOwnerCurrent() else { completion(.ownerChanged); return }
        guard hardwareAvailable() else { completion(.unavailable("NFC tag reading is not available on this device or with its current signing profile. No wake was confirmed.")); return }
        let id = UUID()
        attemptID = id
        self.isOwnerCurrent = isOwnerCurrent
        self.onReady = onReaderReady
        self.completion = completion
        guard let reader = makeReader({ [weak self] event in
            if Thread.isMainThread { self?.receive(event, attempt: id) }
            else { DispatchQueue.main.async { [weak self] in self?.receive(event, attempt: id) } }
        }) else {
            finish(.unavailable("The NFC session could not be created. Verify the NFC entitlement and provisioning profile."), attempt: id); return
        }
        self.reader = reader
        backgroundObserver = notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finish(.cancelled, attempt: id)
        }
        scheduleTimeout { [weak self] in self?.finish(.timedOut, attempt: id) }
        reader.begin()
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard let id = attemptID else { return }
        finish(.cancelled, attempt: id)
    }

    private func receive(_ event: Event, attempt: UUID) {
        guard attemptID == attempt else { return }
        guard isForeground(), isOwnerCurrent?() == true else { finish(.ownerChanged, attempt: attempt); return }
        switch event {
        case .readerReady: onReady?()
        case .tagDetected: finish(.tagObserved, attempt: attempt)
        case .invalidated(.cancelled): finish(.cancelled, attempt: attempt)
        case .invalidated(.timedOut): finish(.timedOut, attempt: attempt)
        case .invalidated(.failed(let reason)): finish(.failed(reason), attempt: attempt)
        }
    }

    private func finish(_ outcome: Outcome, attempt: UUID) {
        guard attemptID == attempt else { return }
        let finalOutcome: Outcome = isOwnerCurrent?() == true ? outcome : .ownerChanged
        let callback = completion, oldReader = reader
        attemptID = nil
        completion = nil
        onReady = nil
        isOwnerCurrent = nil
        reader = nil
        if let backgroundObserver { notifications.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        // Invalidation may synchronously call back; invalidate the owner token first.
        oldReader?.invalidate()
        callback?(finalOutcome)
    }
}

/// Its complete operation surface is begin/invalidate. No tag connect, transceive,
/// proprietary command, NDEF write, Bluetooth or cloud action exists in this adapter.
private final class CoreNFCOttaiWakeReader: NSObject, OttaiNFCWakeReader, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?
    private let event: (OttaiNFCWake.Event) -> Void

    init?(event: @escaping (OttaiNFCWake.Event) -> Void) {
        self.event = event
        super.init()
        guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: .main) else { return nil }
        self.session = session
        session.alertMessage = "Hold the top of iPhone near the Ottai CN / Syai sensor to apply the NFC field. Then check Bluetooth. This does not activate the sensor."
    }

    func begin() { session?.begin() }
    func invalidate() { session?.invalidate(); session = nil }
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        guard self.session === session else { return }
        event(.readerReady)
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard self.session === session, !tags.isEmpty else { return }
        // Do not inspect tag identifiers and do not call session.connect(to:).
        event(.tagDetected)
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard self.session === session else { return }
        self.session = nil
        if let error = error as? NFCReaderError {
            switch error.code {
            case .readerSessionInvalidationErrorUserCanceled: event(.invalidated(.cancelled))
            case .readerSessionInvalidationErrorSessionTimeout: event(.invalidated(.timedOut))
            default: event(.invalidated(.failed("The NFC session ended: " + error.localizedDescription + ". Sensor wake was not confirmed.")))
            }
        } else { event(.invalidated(.failed("The NFC session ended without confirming a sensor wake."))) }
    }
}
