//
//  MinimedPumpManagerRecents.swift
//  MinimedKit
//
//  Copyright © 2019 Pete Schwamb. All rights reserved.
//

import Foundation
import LoopKit

struct MinimedPumpManagerRecents: Equatable {

    internal enum EngageablePumpState: Equatable {
        case engaging
        case disengaging
        case stable
    }

    internal var suspendEngageState: EngageablePumpState = .stable

    internal var bolusEngageState: EngageablePumpState = .stable

    internal var tempBasalEngageState: EngageablePumpState = .stable

    var lastAddedPumpEvents: Date = .distantPast

    var lastBasalScheduleRead: Date = .distantPast
    
    var latestPumpStatus: PumpStatus? = nil

    var latestPumpStatusFromMySentry: MySentryPumpStatusMessageBody? = nil {
        didSet {
            if let sensorState = latestPumpStatusFromMySentry {
                self.sensorState = EnliteSensorDisplayable(sensorState)
            }
        }
    }

    var sensorState: EnliteSensorDisplayable? = nil
}

extension MinimedPumpManagerRecents: CustomDebugStringConvertible {
    var debugDescription: String {
        return """
        ### MinimedPumpManagerRecents
        suspendEngageState: \(suspendEngageState)
        bolusEngageState: \(bolusEngageState)
        tempBasalEngageState: \(tempBasalEngageState)
        lastAddedPumpEvents: \(lastAddedPumpEvents)
        lastBasalScheduleRead: \(lastBasalScheduleRead)
        latestPumpStatus: \(String(describing: latestPumpStatus))
        latestPumpStatusFromMySentry: \(String(describing: latestPumpStatusFromMySentry))
        sensorState: \(String(describing: sensorState))
        """
    }
}
