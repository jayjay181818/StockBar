//
//  ConnectivityMonitor.swift
//  Stockbar
//
//  Service to monitor network connectivity status.
//  Uses NWPathMonitor to detect network changes.
//

import Combine
import Foundation
import Observation
import Network

@MainActor
@Observable
class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()
    
    var isConnected: Bool = true
    var isLowDataMode: Bool = false
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.stockbar.connectivity", qos: .utility)
    private let logger = Logger.shared
    
    private init() {
        startMonitoring()
    }
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let wasConnected = self.isConnected
                let wasLowDataMode = self.isLowDataMode
                let isNowConnected = path.status == .satisfied
                let isNowLowDataMode = path.isConstrained

                if wasConnected != isNowConnected {
                    self.isConnected = isNowConnected
                    if isNowConnected {
                        await self.logger.info("🌐 Network: Connected")
                    } else {
                        // Sleep and changing networks do this many times a day.
                        await self.logger.info("🌐 Network: Disconnected")
                    }
                }

                if wasLowDataMode != isNowLowDataMode {
                    self.isLowDataMode = isNowLowDataMode
                    await self.logger.debug(
                        isNowLowDataMode
                            ? "🌐 Network: Low data mode enabled"
                            : "🌐 Network: Low data mode disabled"
                    )
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    func stopMonitoring() {
        monitor.cancel()
    }
}
