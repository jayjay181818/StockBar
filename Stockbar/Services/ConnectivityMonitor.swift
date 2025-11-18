//
//  ConnectivityMonitor.swift
//  Stockbar
//
//  Service to monitor network connectivity status.
//  Uses NWPathMonitor to detect network changes.
//

import Foundation
import Network
import Combine

@MainActor
class ConnectivityMonitor: ObservableObject {
    static let shared = ConnectivityMonitor()
    
    @Published var isConnected: Bool = true
    @Published var isLowDataMode: Bool = false
    
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
                let isNowConnected = path.status == .satisfied
                
                self.isConnected = isNowConnected
                self.isLowDataMode = path.isConstrained
                
                if wasConnected != isNowConnected {
                    if isNowConnected {
                        await self.logger.info("🌐 Network: Connected")
                    } else {
                        await self.logger.warning("🌐 Network: Disconnected")
                    }
                }
                
                if path.isConstrained {
                    await self.logger.debug("🌐 Network: Low data mode detected")
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    func stopMonitoring() {
        monitor.cancel()
    }
}

