import Foundation
import Combine

/// Manages background portfolio calculation progress and state
@MainActor
class BackgroundCalculationManager: ObservableObject {
    static let shared = BackgroundCalculationManager()
    
    // MARK: - Published Properties
    
    @Published var calculationProgress: Double = 0.0
    @Published var isCalculating: Bool = false
    @Published var calculationStatus: String = ""
    @Published var estimatedTimeRemaining: TimeInterval = 0
    @Published var lastError: String?
    @Published var memoryUsage: String = ""
    @Published var dataPointsCount: Int = 0
    
    // MARK: - Private Properties
    
    private var currentTask: Task<Void, Never>?
    private var startTime: Date?
    private var totalOperations: Int = 0
    private var completedOperations: Int = 0
    private let logger = Logger.shared
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Starts a new calculation with progress tracking
    func startCalculation(operation: String, totalOperations: Int) {
        Task { @MainActor in
            self.isCalculating = true
            self.calculationProgress = 0.0
            self.calculationStatus = operation
            self.totalOperations = totalOperations
            self.completedOperations = 0
            self.startTime = Date()
            self.lastError = nil
            self.estimatedTimeRemaining = 0
            
            Task { await logger.info("📊 PROGRESS: Started \(operation) with \(totalOperations) operations") }
        }
    }
    
    /// Updates calculation progress
    func updateProgress(completed: Int, status: String? = nil) {
        Task { @MainActor in
            // CRITICAL FIX: Validate progress doesn't go backwards or stall
            let newProgress = min(1.0, Double(completed) / Double(max(1, totalOperations)))
            
            if newProgress < calculationProgress && calculationProgress < 1.0 {
                Task { await logger.warning("📊 PROGRESS: Progress went backwards: \(Int(calculationProgress * 100))% -> \(Int(newProgress * 100))%") }
                // Don't update backwards progress unless it's completion
                return
            }
            
            // Check for stalled progress (same progress for too long)
            if let startTime = startTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 600 && newProgress < 0.1 { // 10 minutes with <10% progress
                    Task { await logger.error("📊 PROGRESS: Calculation appears stalled after \(Int(elapsed))s with only \(Int(newProgress * 100))% progress") }
                    reportError("Calculation stalled - taking too long to complete")
                    return
                }
            }
            
            self.completedOperations = completed
            self.calculationProgress = newProgress
            
            if let status = status {
                self.calculationStatus = status
            }
            
            // Calculate estimated time remaining
            if let startTime = startTime, completed > 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = Double(completed) / elapsed
                let remaining = Double(totalOperations - completed) / rate
                self.estimatedTimeRemaining = max(0, remaining)
            }
            
            // Update memory usage
            self.updateMemoryUsage()
            
            Task { await logger.debug("📊 PROGRESS: \(completed)/\(totalOperations) (\(Int(calculationProgress * 100))%) - \(calculationStatus)") }
        }
    }
    
    /// Updates memory usage information
    private func updateMemoryUsage() {
        var memoryInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &memoryInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let memoryUsageBytes = memoryInfo.resident_size
            let memoryUsageMB = Double(memoryUsageBytes) / 1024 / 1024
            
            if memoryUsageMB < 1024 {
                self.memoryUsage = String(format: "%.1f MB", memoryUsageMB)
            } else {
                self.memoryUsage = String(format: "%.2f GB", memoryUsageMB / 1024)
            }
        } else {
            self.memoryUsage = "Unknown"
        }
    }
    
    /// Updates data points count
    func updateDataPointsCount(_ count: Int) {
        Task { @MainActor in
            self.dataPointsCount = count
        }
    }
    
    /// Completes the calculation
    func completeCalculation() {
        Task { @MainActor in
            self.isCalculating = false
            self.calculationProgress = 1.0
            self.estimatedTimeRemaining = 0
            
            if let startTime = startTime {
                let totalTime = Date().timeIntervalSince(startTime)
                Task { await logger.info("📊 PROGRESS: Completed \(calculationStatus) in \(String(format: "%.1f", totalTime))s") }
            }
            
            // Clear status after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if !self.isCalculating {
                    self.calculationStatus = ""
                    self.calculationProgress = 0.0
                }
            }
        }
    }
    
    /// Reports an error during calculation
    func reportError(_ error: String) {
        Task { @MainActor in
            self.lastError = error
            self.isCalculating = false
            Task { await logger.error("📊 PROGRESS ERROR: \(error)") }
            
            // Clear error after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                if self.lastError == error {
                    self.lastError = nil
                }
            }
        }
    }
    
    /// Cancels the current calculation
    func cancelCalculation() {
        currentTask?.cancel()
        
        Task { @MainActor in
            self.isCalculating = false
            self.calculationStatus = "Cancelled"
            self.calculationProgress = 0.0
            self.estimatedTimeRemaining = 0
            
            Task { await logger.info("📊 PROGRESS: Calculation cancelled by user") }
            
            // Clear status after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.calculationStatus = ""
            }
        }
    }
    
    /// Sets the current task for cancellation support
    func setCurrentTask(_ task: Task<Void, Never>) {
        currentTask = task
    }
    
    /// Gets formatted time remaining string
    var formattedTimeRemaining: String {
        if estimatedTimeRemaining <= 0 {
            return ""
        }
        
        if estimatedTimeRemaining < 60 {
            return String(format: "%.0fs remaining", estimatedTimeRemaining)
        } else if estimatedTimeRemaining < 3600 {
            let minutes = Int(estimatedTimeRemaining / 60)
            let seconds = Int(estimatedTimeRemaining.truncatingRemainder(dividingBy: 60))
            return String(format: "%dm %ds remaining", minutes, seconds)
        } else {
            let hours = Int(estimatedTimeRemaining / 3600)
            let minutes = Int((estimatedTimeRemaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return String(format: "%dh %dm remaining", hours, minutes)
        }
    }
    
    /// Gets formatted progress percentage
    var formattedProgress: String {
        return String(format: "%.0f%%", calculationProgress * 100)
    }
}