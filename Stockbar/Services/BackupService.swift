//
//  BackupService.swift
//  Stockbar
//
//  Created for v2.2.10
//  Automatic portfolio backup and restore functionality
//

import Foundation
import Cocoa

/// Service for managing automatic portfolio backups
@MainActor
class BackupService {
    static let shared = BackupService()

    // MARK: - Configuration
    private let backupDirectoryName = "Backups"
    private let backupFilePrefix = "portfolio_backup_"
    private let backupFileExtension = "json"

    /// Default retention period in days
    var retentionDays: Int {
        get { UserDefaults.standard.integer(forKey: "backupRetentionDays") == 0 ? 30 : UserDefaults.standard.integer(forKey: "backupRetentionDays") }
        set { UserDefaults.standard.set(newValue, forKey: "backupRetentionDays") }
    }

    /// Last successful backup date
    var lastBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastBackupDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastBackupDate") }
    }

    private let logger = Logger.shared
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Backup Directory Management

    /// Returns the backup directory URL, creating it if needed
    func getBackupDirectory() throws -> URL {
        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let stockbarDir = appSupport.appendingPathComponent("Stockbar")
        let backupDir = stockbarDir.appendingPathComponent(backupDirectoryName)

        if !fileManager.fileExists(atPath: backupDir.path) {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
            Task { await logger.info("Created backup directory at: \(backupDir.path)") }
        }

        return backupDir
    }

    /// Opens the backup directory in Finder
    func openBackupDirectory() {
        do {
            let backupDir = try getBackupDirectory()
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backupDir.path)
        } catch {
            Task { await logger.error("Failed to open backup directory: \(error.localizedDescription)") }
        }
    }

    // MARK: - Backup Operations

    /// Performs automatic daily backup if needed
    func performAutomaticBackupIfNeeded(trades: [RealTimeTrade]) async -> Bool {
        // Check if backup was already done today
        if let lastBackup = lastBackupDate,
           Calendar.current.isDateInToday(lastBackup) {
            await logger.debug("Backup already performed today, skipping")
            return true
        }

        return await performBackup(trades: trades, automatic: true)
    }

    /// Performs manual backup
    func performManualBackup(trades: [RealTimeTrade]) async -> Bool {
        return await performBackup(trades: trades, automatic: false)
    }

    /// Core backup implementation
    private func performBackup(trades: [RealTimeTrade], automatic: Bool) async -> Bool {
        do {
            let backupDir = try getBackupDirectory()

            // Generate filename with today's date
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateString = dateFormatter.string(from: Date())

            // Add time suffix for manual backups (allow multiple per day)
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HHmmss"
            let timeString = automatic ? "" : "_\(timeFormatter.string(from: Date()))"

            let filename = "\(backupFilePrefix)\(dateString)\(timeString).\(backupFileExtension)"
            let backupURL = backupDir.appendingPathComponent(filename)

            // Convert trades to exportable format
            let exportData = trades.map { trade in
                PortfolioExportData(from: trade.trade)
            }

            // Encode to JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let jsonData = try encoder.encode(exportData)
            try jsonData.write(to: backupURL)

            // Update last backup date
            lastBackupDate = Date()

            // Cleanup old backups
            try await cleanupOldBackups()

            await logger.info("Backup successful: \(filename)")
            return true

        } catch {
            await logger.error("Backup failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Restore Operations

    /// Lists all available backup files
    func listAvailableBackups() -> [BackupInfo] {
        do {
            let backupDir = try getBackupDirectory()
            let contents = try fileManager.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: .skipsHiddenFiles)

            let backups = contents
                .filter { $0.pathExtension == backupFileExtension && $0.lastPathComponent.starts(with: backupFilePrefix) }
                .compactMap { url -> BackupInfo? in
                    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                          let creationDate = attributes[.creationDate] as? Date,
                          let fileSize = attributes[.size] as? Int64 else {
                        return nil
                    }

                    return BackupInfo(url: url, date: creationDate, size: fileSize)
                }
                .sorted { $0.date > $1.date } // Most recent first

            return backups

        } catch {
            Task { await logger.error("Failed to list backups: \(error.localizedDescription)") }
            return []
        }
    }

    /// Restores portfolio from a backup file
    func restoreFromBackup(backupURL: URL) async throws -> [Trade] {
        await logger.info("Restoring from backup: \(backupURL.lastPathComponent)")

        let data = try Data(contentsOf: backupURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exportData = try decoder.decode([PortfolioExportData].self, from: data)
        let trades = exportData.map { $0.toTrade() }

        await logger.info("Successfully restored \(trades.count) trades from backup")
        return trades
    }

    /// Preview backup contents without restoring
    func previewBackup(backupURL: URL) throws -> [PortfolioExportData] {
        let data = try Data(contentsOf: backupURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode([PortfolioExportData].self, from: data)
    }

    // MARK: - Cleanup

    /// Removes backups older than retention period
    private func cleanupOldBackups() async throws {
        let backupDir = try getBackupDirectory()
        let contents = try fileManager.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!

        var deletedCount = 0
        for fileURL in contents {
            guard fileURL.pathExtension == backupFileExtension,
                  fileURL.lastPathComponent.starts(with: backupFilePrefix) else {
                continue
            }

            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let creationDate = attributes[.creationDate] as? Date,
               creationDate < cutoffDate {
                try fileManager.removeItem(at: fileURL)
                deletedCount += 1
                await logger.debug("Deleted old backup: \(fileURL.lastPathComponent)")
            }
        }

        if deletedCount > 0 {
            await logger.info("Cleaned up \(deletedCount) old backup(s)")
        }
    }

    /// Deletes a specific backup file
    func deleteBackup(backupURL: URL) throws {
        try fileManager.removeItem(at: backupURL)
        Task { await logger.info("Deleted backup: \(backupURL.lastPathComponent)") }
    }

    /// Deletes all backup files
    func deleteAllBackups() throws {
        let backups = listAvailableBackups()
        for backup in backups {
            try deleteBackup(backupURL: backup.url)
        }
        Task { await logger.info("Deleted all \(backups.count) backup(s)")  }
    }
}

// MARK: - Supporting Types

/// Information about a backup file
struct BackupInfo: Identifiable {
    let id = UUID()
    let url: URL
    let date: Date
    let size: Int64

    var filename: String {
        url.lastPathComponent
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}