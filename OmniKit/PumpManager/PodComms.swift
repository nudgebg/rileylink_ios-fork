//
//  PodComms.swift
//  OmniKit
//
//  Created by Pete Schwamb on 10/7/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import Foundation
import RileyLinkBLEKit
import LoopKit
import os.log


protocol PodCommsDelegate: class {
    func podComms(_ podComms: PodComms, didChange podState: PodState)
}

class PodComms: CustomDebugStringConvertible {
    
    private let configuredDevices: Locked<Set<RileyLinkDevice>> = Locked(Set())
    
    weak var delegate: PodCommsDelegate?
    
    weak var messageLogger: MessageLogger?

    public let log = OSLog(category: "PodComms")

    private var startingPacketNumber = 0

    // Only valid to access on the session serial queue
    private var podState: PodState? {
        didSet {
            if let newValue = podState, newValue != oldValue {
                //log.debug("Notifying delegate of new podState: %{public}@", String(reflecting: newValue))
                delegate?.podComms(self, didChange: newValue)
            }
        }
    }
    
    init(podState: PodState?) {
        self.podState = podState
        self.delegate = nil
        self.messageLogger = nil
    }
    
    /// Handles all the common work to send and verify the version response for the two pairing commands, AssignAddress and SetupPod.
    ///  Has side effects of creating pod state, assigning startingPacketNumber, and updating pod state.
    ///
    /// - parameter address: Address being assigned to the pod
    /// - parameter transport: PodMessageTransport used to send messages
    /// - parameter message: Message to send; must be an AssignAddress or SetupPod
    ///
    /// - returns: The VersionResponse from the pod
    ///
    /// - Throws:
    ///     - PodCommsError.noResponse
    ///     - PodCommsError.podAckedInsteadOfReturningResponse
    ///     - PodCommsError.unexpectedPacketType
    ///     - PodCommsError.emptyResponse
    ///     - PodCommsError.unexpectedResponse
    ///     - PodCommsError.podChange
    ///     - PodCommsError.rssiTooLow
    ///     - PodCommsError.rssiTooHigh
    ///     - PodCommsError.activationTimeExceeded
    ///     - MessageError.invalidCrc
    ///     - MessageError.invalidSequence
    ///     - MessageError.invalidAddress
    ///     - RileyLinkDeviceError
    private func sendPairMessage(address: UInt32, transport: PodMessageTransport, message: Message) throws -> VersionResponse {

        defer {
            log.debug("sendPairMessage saving current transport packet #%d", transport.packetNumber)
            if self.podState != nil {
                self.podState!.messageTransportState = MessageTransportState(packetNumber: transport.packetNumber, messageNumber: transport.messageNumber)
            } else {
                self.startingPacketNumber = transport.packetNumber
            }
        }

        var didRetry = false
        
        var rssiRetries = 2
        while true {
            let response: Message
            do {
                response = try transport.sendMessage(message)
            } catch let error {
                if let podCommsError = error as? PodCommsError {
                    switch podCommsError {
                    // These errors can happen some times when the responses are not seen for a long
                    // enough time. Automatically retrying using the already incremented packet # can
                    // clear this condition without requiring any user interaction for a pairing failure.
                    case .podAckedInsteadOfReturningResponse, .noResponse:
                        if didRetry == false {
                            didRetry = true
                            log.debug("sendPairMessage to retry using updated packet #%d", transport.packetNumber)
                            continue // the transport packet # is already advanced for the retry
                        }
                    default:
                        break
                    }
                }
                throw error
            }

            if let fault = response.fault {
                log.error("Pod Fault: %{public}@", String(describing: fault))
                if let podState = self.podState, podState.fault == nil {
                    self.podState!.fault = fault
                }
                throw PodCommsError.podFault(fault: fault)
            }

            guard let config = response.messageBlocks[0] as? VersionResponse else {
                log.error("sendPairMessage unexpected response: %{public}@", String(describing: response))
                let responseType = response.messageBlocks[0].blockType
                throw PodCommsError.unexpectedResponse(response: responseType)
            }

            guard config.address == address else {
                log.error("sendPairMessage unexpected address return of %{public}@ instead of expected %{public}@",
                  String(format: "04X", config.address), String(format: "%04X", address))
                throw PodCommsError.invalidAddress(address: config.address, expectedAddress: address)
            }

            // If we previously had podState, verify that we are still dealing with the same pod
            if let podState = self.podState, (podState.lot != config.lot || podState.tid != config.tid) {
                // Have a new pod, could be a pod change w/o deactivation (or we're picking up some other pairing pod!)
                log.error("Received pod response for [lot %u tid %u], expected [lot %u tid %u]", config.lot, config.tid, podState.lot, podState.tid)
                throw PodCommsError.podChange
            }

            // Checking RSSI
            let maxRssiAllowed = 59         // maximum RSSI limit allowed
            let minRssiAllowed = 30         // minimum RSSI limit allowed
            if let rssi = config.rssi, let gain = config.gain {
                let rssiStr = String(format: "Receiver Low Gain: %d.\nReceived Signal Strength Indicator: %d", gain, rssi)
                log.default("%s", rssiStr)
                rssiRetries -= 1
                if rssi < minRssiAllowed {
                    log.default("RSSI value %d is less than minimum allowed value of %d, %d retries left", rssi, minRssiAllowed, rssiRetries)
                    if rssiRetries > 0 {
                        continue
                    }
                    throw PodCommsError.rssiTooLow
                }
                if rssi > maxRssiAllowed {
                    log.default("RSSI value %d is more than maximum allowed value of %d, %d retries left", rssi, maxRssiAllowed, rssiRetries)
                    if rssiRetries > 0 {
                        continue
                    }
                    throw PodCommsError.rssiTooHigh
                }
            }

            if self.podState == nil {
                log.default("Creating PodState for address %{public}@ [lot %u tid %u], packet #%d, message #%d", String(format: "%04X", config.address), config.lot, config.tid, transport.packetNumber, transport.messageNumber)
                self.podState = PodState(
                    address: config.address,
                    piVersion: String(describing: config.piVersion),
                    pmVersion: String(describing: config.pmVersion),
                    lot: config.lot,
                    tid: config.tid,
                    packetNumber: transport.packetNumber,
                    messageNumber: transport.messageNumber
                )
                // podState setupProgress state should be addressAssigned
            }

            // Now that we have podState, check for an activation timeout condition that can be noted in setupProgress
            guard config.podProgressStatus != .activationTimeExceeded else {
                // The 2 hour window for the initial pairing has expired
                self.podState?.setupProgress = .activationTimeout
                throw PodCommsError.activationTimeExceeded
            }

            if config.podProgressStatus == .pairingCompleted {
                log.info("Version Response %{public}@ indicates pairing is complete, moving pod to configured state", String(describing: config))
                self.podState?.setupProgress = .podConfigured
            }

            return config
        }
    }

    private func assignAddress(address: UInt32, commandSession: CommandSession) throws {
        commandSession.assertOnSessionQueue()

        let packetNumber, messageNumber: Int
        if let podState = self.podState {
            packetNumber = podState.messageTransportState.packetNumber
            messageNumber = podState.messageTransportState.messageNumber
        } else {
            packetNumber = self.startingPacketNumber
            messageNumber = 0
        }

        log.debug("Attempting pairing with address %{public}@ using packet #%d", String(format: "%04X", address), packetNumber)
        let messageTransportState = MessageTransportState(packetNumber: packetNumber, messageNumber: messageNumber)
        let transport = PodMessageTransport(session: commandSession, address: 0xffffffff, ackAddress: address, state: messageTransportState)
        transport.messageLogger = messageLogger
        
        // Create the Assign Address command message
        let assignAddress = AssignAddressCommand(address: address)
        let message = Message(address: 0xffffffff, messageBlocks: [assignAddress], sequenceNum: transport.messageNumber)

        _ = try sendPairMessage(address: address, transport: transport, message: message)
    }
    
    private func setupPod(podState: PodState, timeZone: TimeZone, commandSession: CommandSession) throws {
        commandSession.assertOnSessionQueue()
        
        let transport = PodMessageTransport(session: commandSession, address: 0xffffffff, ackAddress: podState.address, state: podState.messageTransportState)
        transport.messageLogger = messageLogger
        
        let dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)
        let setupPod = SetupPodCommand(address: podState.address, dateComponents: dateComponents, lot: podState.lot, tid: podState.tid)
        
        let message = Message(address: 0xffffffff, messageBlocks: [setupPod], sequenceNum: transport.messageNumber)
        
        let versionResponse: VersionResponse
        do {
            versionResponse = try sendPairMessage(address: podState.address, transport: transport, message: message)
        } catch let error {
            if case PodCommsError.podAckedInsteadOfReturningResponse = error {
                log.default("SetupPod acked instead of returning response. Moving pod to configured state.")
                self.podState?.setupProgress = .podConfigured
                return
            }
            log.error("SetupPod returns error %{public}@", String(describing: error))
            throw error
        }

        guard versionResponse.isSetupPodVersionResponse else {
            log.error("SetupPod unexpected VersionResponse type: %{public}@", String(describing: versionResponse))
            throw PodCommsError.invalidData
        }
    }
    
    func assignAddressAndSetupPod(address: UInt32, using deviceSelector: @escaping (_ completion: @escaping (_ device: RileyLinkDevice?) -> Void) -> Void, timeZone: TimeZone, messageLogger: MessageLogger?, _ block: @escaping (_ result: SessionRunResult) -> Void)
    {
        deviceSelector { (device) in
            guard let device = device else {
                block(.failure(PodCommsError.noRileyLinkAvailable))
                return
            }

            device.runSession(withName: "Pair Pod") { (commandSession) in
                do {
                    self.configureDevice(device, with: commandSession)
                    
                    if self.podState == nil {
                        try self.assignAddress(address: address, commandSession: commandSession)
                    }
                    
                    guard self.podState != nil else {
                        block(.failure(PodCommsError.noPodPaired))
                        return
                    }

                    if self.podState!.setupProgress != .podConfigured {
                        try self.setupPod(podState: self.podState!, timeZone: timeZone, commandSession: commandSession)
                    }

                    guard self.podState!.setupProgress == .podConfigured else {
                        self.log.error("Unexpected podStatus setupProgress value of %{public}@", String(describing: self.podState!.setupProgress))
                        throw PodCommsError.invalidData
                    }
                    self.startingPacketNumber = 0

                    // Run a session now for any post-pairing commands
                    let transport = PodMessageTransport(session: commandSession, address: self.podState!.address, state: self.podState!.messageTransportState)
                    transport.messageLogger = self.messageLogger
                    let podSession = PodCommsSession(podState: self.podState!, transport: transport, delegate: self)

                    block(.success(session: podSession))
                } catch let error as PodCommsError {
                    block(.failure(error))
                } catch {
                    block(.failure(PodCommsError.commsError(error: error)))
                }
            }
        }
    }
    
    enum SessionRunResult {
        case success(session: PodCommsSession)
        case failure(PodCommsError)
    }
    
    func runSession(withName name: String, using deviceSelector: @escaping (_ completion: @escaping (_ device: RileyLinkDevice?) -> Void) -> Void, _ block: @escaping (_ result: SessionRunResult) -> Void) {

        deviceSelector { (device) in
            guard let device = device else {
                block(.failure(PodCommsError.noRileyLinkAvailable))
                return
            }

            device.runSession(withName: name) { (commandSession) in
                guard self.podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

                self.configureDevice(device, with: commandSession)
                let transport = PodMessageTransport(session: commandSession, address: self.podState!.address, state: self.podState!.messageTransportState)
                transport.messageLogger = self.messageLogger
                let podSession = PodCommsSession(podState: self.podState!, transport: transport, delegate: self)
                block(.success(session: podSession))
            }
        }
    }
    
    // Must be called from within the RileyLinkDevice sessionQueue
    private func configureDevice(_ device: RileyLinkDevice, with session: CommandSession) {
        session.assertOnSessionQueue()

        guard !self.configuredDevices.value.contains(device) else {
            return
        }
        
        do {
            log.debug("configureRadio (omnipod)")
            _ = try session.configureRadio()
        } catch let error {
            log.error("configure Radio failed with error: %{public}@", String(describing: error))
            // Ignore the error and let the block run anyway
            return
        }
        
        NotificationCenter.default.post(name: .DeviceRadioConfigDidChange, object: device)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceRadioConfigDidChange(_:)), name: .DeviceRadioConfigDidChange, object: device)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceRadioConfigDidChange(_:)), name: .DeviceConnectionStateDidChange, object: device)
        
        log.debug("added device %{public}@ to configuredDevices", device.name ?? "unknown")
        _ = configuredDevices.mutate { (value) in
            value.insert(device)
        }
    }
    
    @objc private func deviceRadioConfigDidChange(_ note: Notification) {
        guard let device = note.object as? RileyLinkDevice else {
            return
        }
        log.debug("removing device %{public}@ from configuredDevices", device.name ?? "unknown")

        NotificationCenter.default.removeObserver(self, name: .DeviceRadioConfigDidChange, object: device)
        NotificationCenter.default.removeObserver(self, name: .DeviceConnectionStateDidChange, object: device)

        _ = configuredDevices.mutate { (value) in
            value.remove(device)
        }
    }
    
    // MARK: - CustomDebugStringConvertible
    
    var debugDescription: String {
        return [
            "## PodComms",
            "podState: \(String(reflecting: podState))",
            "configuredDevices: \(configuredDevices.value.map { $0.peripheralIdentifier.uuidString })",
            "delegate: \(String(describing: delegate != nil))",
            ""
        ].joined(separator: "\n")
    }

}

extension PodComms: PodCommsSessionDelegate {
    func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState) {
        podCommsSession.assertOnSessionQueue()
        self.podState = state
    }
}


private extension CommandSession {
    
    func configureRadio() throws {
        
        //        SYNC1     |0xDF00|0x54|Sync Word, High Byte
        //        SYNC0     |0xDF01|0xC3|Sync Word, Low Byte
        //        PKTLEN    |0xDF02|0x32|Packet Length
        //        PKTCTRL1  |0xDF03|0x24|Packet Automation Control
        //        PKTCTRL0  |0xDF04|0x00|Packet Automation Control
        //        FSCTRL1   |0xDF07|0x06|Frequency Synthesizer Control
        //        FREQ2     |0xDF09|0x12|Frequency Control Word, High Byte
        //        FREQ1     |0xDF0A|0x14|Frequency Control Word, Middle Byte
        //        FREQ0     |0xDF0B|0x5F|Frequency Control Word, Low Byte
        //        MDMCFG4   |0xDF0C|0xCA|Modem configuration
        //        MDMCFG3   |0xDF0D|0xBC|Modem Configuration
        //        MDMCFG2   |0xDF0E|0x0A|Modem Configuration
        //        MDMCFG1   |0xDF0F|0x13|Modem Configuration
        //        MDMCFG0   |0xDF10|0x11|Modem Configuration
        //        MCSM0     |0xDF14|0x18|Main Radio Control State Machine Configuration
        //        FOCCFG    |0xDF15|0x17|Frequency Offset Compensation Configuration
        //        AGCCTRL1  |0xDF18|0x70|AGC Control
        //        FSCAL3    |0xDF1C|0xE9|Frequency Synthesizer Calibration
        //        FSCAL2    |0xDF1D|0x2A|Frequency Synthesizer Calibration
        //        FSCAL1    |0xDF1E|0x00|Frequency Synthesizer Calibration
        //        FSCAL0    |0xDF1F|0x1F|Frequency Synthesizer Calibration
        //        TEST1     |0xDF24|0x31|Various Test Settings
        //        TEST0     |0xDF25|0x09|Various Test Settings
        //        PA_TABLE0 |0xDF2E|0x60|PA Power Setting 0
        //        VERSION   |0xDF37|0x04|Chip ID[7:0]
        
        try setSoftwareEncoding(.manchester)
        try setPreamble(0x6665)
        try setBaseFrequency(Measurement(value: 433.91, unit: .megahertz))
        try updateRegister(.pktctrl1, value: 0x20)
        try updateRegister(.pktctrl0, value: 0x00)
        try updateRegister(.fsctrl1, value: 0x06)
        try updateRegister(.mdmcfg4, value: 0xCA)
        try updateRegister(.mdmcfg3, value: 0xBC)  // 0xBB for next lower bitrate
        try updateRegister(.mdmcfg2, value: 0x06)
        try updateRegister(.mdmcfg1, value: 0x70)
        try updateRegister(.mdmcfg0, value: 0x11)
        try updateRegister(.deviatn, value: 0x44)
        try updateRegister(.mcsm0, value: 0x18)
        try updateRegister(.foccfg, value: 0x17)
        try updateRegister(.fscal3, value: 0xE9)
        try updateRegister(.fscal2, value: 0x2A)
        try updateRegister(.fscal1, value: 0x00)
        try updateRegister(.fscal0, value: 0x1F)
        
        try updateRegister(.test1, value: 0x31)
        try updateRegister(.test0, value: 0x09)
        try updateRegister(.paTable0, value: 0x84)
        try updateRegister(.sync1, value: 0xA5)
        try updateRegister(.sync0, value: 0x5A)
    }

    // This is just a testing function for spoofing PDM packets, or other times when you need to generate a custom packet
    private func sendPacket() throws {
        let packetNumber = 19
        let messageNumber = 0x24 >> 2
        let address: UInt32 = 0x1f0b3554

        let cmd = GetStatusCommand(podInfoType: .normal)

        let message = Message(address: address, messageBlocks: [cmd], sequenceNum: messageNumber)

        var dataRemaining = message.encoded()

        let sendPacket = Packet(address: address, packetType: .pdm, sequenceNum: packetNumber, data: dataRemaining)
        dataRemaining = dataRemaining.subdata(in: sendPacket.data.count..<dataRemaining.count)

        let _ = try sendAndListen(sendPacket.encoded(), repeatCount: 0, timeout: .milliseconds(333), retryCount: 0, preambleExtension: .milliseconds(127))

        throw PodCommsError.emptyResponse
    }
}
