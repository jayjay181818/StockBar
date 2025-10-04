//
//  SectorAnalysisService.swift
//  Stockbar
//
//  Created by Claude Code on 2025-10-03.
//  Sector allocation and industry breakdown analysis
//

import Foundation

/// Service for sector classification and allocation analysis
actor SectorAnalysisService {

    // MARK: - Data Models

    /// Sector allocation information
    struct SectorAllocation: Identifiable {
        let id = UUID()
        let sector: Sector
        let totalValue: Double
        let percentageOfPortfolio: Double
        let dayChange: Double
        let dayChangePercent: Double
        let positions: [PositionSummary]

        var industryBreakdown: [IndustryAllocation] {
            var industryMap: [String: (value: Double, symbols: [String])] = [:]

            for position in positions {
                if let industry = position.industry {
                    if var existing = industryMap[industry] {
                        existing.value += position.value
                        existing.symbols.append(position.symbol)
                        industryMap[industry] = existing
                    } else {
                        industryMap[industry] = (value: position.value, symbols: [position.symbol])
                    }
                }
            }

            return industryMap.map { industry, data in
                IndustryAllocation(
                    industry: industry,
                    value: data.value,
                    percentage: totalValue > 0 ? (data.value / totalValue) * 100 : 0,
                    positions: data.symbols
                )
            }.sorted { $0.value > $1.value }
        }
    }

    /// Industry allocation within a sector
    struct IndustryAllocation: Identifiable {
        let id = UUID()
        let industry: String
        let value: Double
        let percentage: Double
        let positions: [String]
    }

    /// Position summary for sector analysis
    struct PositionSummary: Identifiable {
        let id = UUID()
        let symbol: String
        let sector: Sector
        let industry: String?
        let value: Double
        let percentageOfSector: Double
        let percentageOfPortfolio: Double
    }

    /// Standard sector classification (GICS sectors)
    enum Sector: String, CaseIterable, Codable {
        case technology = "Technology"
        case healthcare = "Healthcare"
        case financials = "Financials"
        case consumerCyclical = "Consumer Cyclical"
        case consumerDefensive = "Consumer Defensive"
        case industrials = "Industrials"
        case energy = "Energy"
        case utilities = "Utilities"
        case realEstate = "Real Estate"
        case basicMaterials = "Basic Materials"
        case communicationServices = "Communication Services"
        case unknown = "Unknown"

        var displayName: String {
            return rawValue
        }

        /// Get sector for a given symbol using known mappings
        static func forSymbol(_ symbol: String) -> Sector {
            let symbolUpper = symbol.uppercased().replacingOccurrences(of: ".L", with: "")

            // Comprehensive stock sector mappings (US & UK)
            let sectorMap: [String: Sector] = [
                // ===== US STOCKS =====

                // Technology
                "AAPL": .technology, "MSFT": .technology, "GOOGL": .technology, "GOOG": .technology,
                "AMZN": .consumerCyclical, "META": .communicationServices, "NVDA": .technology,
                "TSLA": .consumerCyclical, "AVGO": .technology, "ORCL": .technology,
                "CRM": .technology, "ADBE": .technology, "CSCO": .technology, "INTC": .technology,
                "AMD": .technology, "QCOM": .technology, "IBM": .technology, "NOW": .technology,
                "SNOW": .technology, "PLTR": .technology, "NET": .technology, "CRWD": .technology,
                "ZS": .technology, "DDOG": .technology, "MDB": .technology, "WDAY": .technology,

                // Healthcare
                "JNJ": .healthcare, "UNH": .healthcare, "LLY": .healthcare, "PFE": .healthcare,
                "ABBV": .healthcare, "TMO": .healthcare, "MRK": .healthcare, "ABT": .healthcare,
                "DHR": .healthcare, "BMY": .healthcare, "AMGN": .healthcare, "CVS": .healthcare,
                "GILD": .healthcare, "VRTX": .healthcare, "ISRG": .healthcare, "REGN": .healthcare,
                "CI": .healthcare, "HUM": .healthcare, "BSX": .healthcare, "MDT": .healthcare,

                // Financials
                "BRK.B": .financials, "JPM": .financials, "V": .financials, "MA": .financials,
                "BAC": .financials, "WFC": .financials, "GS": .financials, "MS": .financials,
                "SCHW": .financials, "AXP": .financials, "BLK": .financials, "C": .financials,
                "USB": .financials, "PNC": .financials, "TFC": .financials, "COF": .financials,
                "CME": .financials, "ICE": .financials, "SPGI": .financials, "MCO": .financials,

                // Consumer Cyclical
                "HD": .consumerCyclical, "MCD": .consumerCyclical, "NKE": .consumerCyclical,
                "SBUX": .consumerCyclical, "LOW": .consumerCyclical, "TJX": .consumerCyclical,
                "BKNG": .consumerCyclical, "MAR": .consumerCyclical, "GM": .consumerCyclical,
                "F": .consumerCyclical, "ABNB": .consumerCyclical, "UBER": .consumerCyclical,

                // Consumer Defensive
                "WMT": .consumerDefensive, "PG": .consumerDefensive, "KO": .consumerDefensive,
                "PEP": .consumerDefensive, "COST": .consumerDefensive, "PM": .consumerDefensive,
                "MO": .consumerDefensive, "CL": .consumerDefensive, "KMB": .consumerDefensive,
                "GIS": .consumerDefensive, "K": .consumerDefensive, "HSY": .consumerDefensive,

                // Energy
                "XOM": .energy, "CVX": .energy, "COP": .energy, "SLB": .energy, "EOG": .energy,
                "MPC": .energy, "PSX": .energy, "VLO": .energy, "OXY": .energy, "HAL": .energy,

                // Industrials
                "BA": .industrials, "HON": .industrials, "UPS": .industrials, "CAT": .industrials,
                "GE": .industrials, "MMM": .industrials, "LMT": .industrials, "RTX": .industrials,
                "DE": .industrials, "UNP": .industrials, "FDX": .industrials, "NSC": .industrials,

                // Communication Services
                "DIS": .communicationServices, "NFLX": .communicationServices, "CMCSA": .communicationServices,
                "VZ": .communicationServices, "T": .communicationServices, "TMUS": .communicationServices,
                "CHTR": .communicationServices, "EA": .communicationServices, "TTWO": .communicationServices,

                // Utilities
                "NEE": .utilities, "DUK": .utilities, "SO": .utilities, "D": .utilities,
                "AEP": .utilities, "EXC": .utilities, "SRE": .utilities, "XEL": .utilities,

                // Real Estate
                "AMT": .realEstate, "PLD": .realEstate, "CCI": .realEstate, "EQIX": .realEstate,
                "PSA": .realEstate, "WELL": .realEstate, "DLR": .realEstate, "AVB": .realEstate,

                // Basic Materials
                "LIN": .basicMaterials, "APD": .basicMaterials, "ECL": .basicMaterials, "SHW": .basicMaterials,
                "NEM": .basicMaterials, "FCX": .basicMaterials, "NUE": .basicMaterials, "DD": .basicMaterials,

                // ===== UK STOCKS (FTSE 100) =====

                // UK Technology
                "SAGE": .technology, "AUTO": .technology, "DARK": .technology,

                // UK Healthcare
                "AZN": .healthcare, "GSK": .healthcare, "BATS": .healthcare,
                "OCDO": .healthcare, "AAF": .healthcare, "HIK": .healthcare,
                "HIMS": .healthcare, // Hims & Hers Health (US)

                // UK Financials
                "LLOY": .financials, "BARC": .financials, "NWG": .financials, "STAN": .financials,
                "HSBA": .financials, "PRU": .financials, "AVIV": .financials, "LGEN": .financials,
                "III": .financials, "STJ": .financials, "BNZL": .financials,
                "LSE": .financials, "EXPN": .financials, "LSEG": .financials,
                "AV": .financials, // Aviva (UK insurance)
                "OSCR": .financials, // Oscar Health (US)

                // UK Consumer Cyclical
                "TSCO": .consumerCyclical, "MKS": .consumerCyclical, "SBRY": .consumerCyclical,
                "WTB": .consumerCyclical, "JD": .consumerCyclical, "FRAS": .consumerCyclical,
                "NEXT": .consumerCyclical, "BDEV": .consumerCyclical, "INF": .consumerCyclical,
                "PSON": .consumerCyclical, "BRBY": .consumerCyclical,
                "EZJ": .consumerCyclical, "CCH": .consumerCyclical, "WPP": .consumerCyclical,
                "TW": .consumerCyclical, // Taylor Wimpey (UK housebuilder)
                "BABA": .consumerCyclical, // Alibaba (China)

                // UK Consumer Defensive
                "ULVR": .consumerDefensive, "DGE": .consumerDefensive, "ABF": .consumerDefensive,
                "RKT": .consumerDefensive, "IMB": .consumerDefensive, "CPG": .consumerDefensive,

                // UK Energy
                "BP": .energy, "SHEL": .energy, "RDSA": .energy, "RDSB": .energy,

                // UK Industrials
                "RR": .industrials, "IMI": .industrials, "SMWH": .industrials, "RMV": .industrials,
                "SPX": .industrials, "WEIR": .industrials, "MGGT": .industrials, "SGE": .industrials,
                "IAG": .industrials, // International Airlines Group (British Airways parent)

                // UK Communication Services
                "VOD": .communicationServices, "BT.A": .communicationServices, "ITV": .communicationServices,
                "REL": .communicationServices, "RMG": .communicationServices,

                // UK Utilities
                "SSE": .utilities, "NG": .utilities, "UU": .utilities, "SVT": .utilities,
                "PERC": .utilities,

                // UK Real Estate
                "LAND": .realEstate, "SGRO": .realEstate, "BLND": .realEstate, "PSN": .realEstate,
                "BBOX": .realEstate, "SAFE": .realEstate, "DIGS": .realEstate,

                // UK Basic Materials
                "RIO": .basicMaterials, "GLEN": .basicMaterials,
                "ANTO": .basicMaterials, "CRH": .basicMaterials, "JMAT": .basicMaterials,

                // ===== ADDITIONAL US STOCKS =====
                "MU": .technology // Micron Technology (semiconductors)
            ]

            // Try exact match first
            if let sector = sectorMap[symbolUpper] {
                return sector
            }

            // Try without .L suffix for UK stocks
            if symbol.uppercased().hasSuffix(".L") {
                let baseSymbol = symbolUpper.replacingOccurrences(of: ".L", with: "")
                if let sector = sectorMap[baseSymbol] {
                    return sector
                }
            }

            return .unknown
        }
    }

    /// Diversification analysis
    struct DiversificationAnalysis {
        let score: Double  // 0-100 (100 = perfectly diversified)
        let concentrationRisk: ConcentrationRisk
        let recommendations: [String]
        let topHeavySectors: [Sector]

        enum ConcentrationRisk: String {
            case low = "Low"
            case medium = "Medium"
            case high = "High"

            var threshold: Double {
                switch self {
                case .low: return 25.0
                case .medium: return 50.0
                case .high: return 100.0
                }
            }
        }
    }

    // MARK: - Sector Allocation Calculation

    /// Calculate sector allocations from portfolio positions
    /// - Parameters:
    ///   - positions: Dictionary mapping symbols to their current market values
    ///   - dayChanges: Dictionary mapping symbols to their day change values
    /// - Returns: Array of sector allocations sorted by value
    func calculateSectorAllocations(
        positions: [String: Double],
        dayChanges: [String: Double]
    ) async -> [SectorAllocation] {
        await Logger.shared.debug("📊 Calculating sector allocations for \(positions.count) positions")

        let totalPortfolioValue = positions.values.reduce(0, +)

        // Group positions by sector
        var sectorMap: [Sector: (value: Double, change: Double, positions: [PositionSummary])] = [:]

        for (symbol, value) in positions {
            let sector = Sector.forSymbol(symbol)
            let change = dayChanges[symbol] ?? 0.0

            let positionSummary = PositionSummary(
                symbol: symbol,
                sector: sector,
                industry: nil,  // Industry mapping would require external data source
                value: value,
                percentageOfSector: 0,  // Will calculate after grouping
                percentageOfPortfolio: totalPortfolioValue > 0 ? (value / totalPortfolioValue) * 100 : 0
            )

            if var existing = sectorMap[sector] {
                existing.value += value
                existing.change += change
                existing.positions.append(positionSummary)
                sectorMap[sector] = existing
            } else {
                sectorMap[sector] = (value: value, change: change, positions: [positionSummary])
            }
        }

        // Create sector allocations with updated percentages
        var allocations: [SectorAllocation] = []

        for (sector, data) in sectorMap {
            let percentage = totalPortfolioValue > 0 ? (data.value / totalPortfolioValue) * 100 : 0
            let changePercent = data.value > 0 ? (data.change / (data.value - data.change)) * 100 : 0

            // Update position percentages within sector
            let updatedPositions = data.positions.map { pos in
                PositionSummary(
                    symbol: pos.symbol,
                    sector: pos.sector,
                    industry: pos.industry,
                    value: pos.value,
                    percentageOfSector: data.value > 0 ? (pos.value / data.value) * 100 : 0,
                    percentageOfPortfolio: pos.percentageOfPortfolio
                )
            }.sorted { $0.value > $1.value }

            allocations.append(SectorAllocation(
                sector: sector,
                totalValue: data.value,
                percentageOfPortfolio: percentage,
                dayChange: data.change,
                dayChangePercent: changePercent,
                positions: updatedPositions
            ))
        }

        // Sort by value descending
        allocations.sort { $0.totalValue > $1.totalValue }

        await Logger.shared.debug("📊 Sector allocations calculated: \(allocations.count) sectors")
        return allocations
    }

    // MARK: - Diversification Analysis

    /// Analyze portfolio diversification across sectors
    func analyzeDiversification(
        sectorAllocations: [SectorAllocation]
    ) async -> DiversificationAnalysis {
        await Logger.shared.debug("📊 Analyzing sector diversification")

        let totalValue = sectorAllocations.reduce(0.0) { $0 + $1.totalValue }

        // Calculate Herfindahl index (concentration measure)
        let herfindahlIndex = sectorAllocations.reduce(0.0) { sum, allocation in
            let weight = allocation.totalValue / totalValue
            return sum + (weight * weight)
        }

        // Diversification score (inverse of concentration)
        // Perfect diversification (equal weights across 11 sectors) = 1/11 ≈ 0.091
        // Maximum concentration (100% in 1 sector) = 1.0
        let idealHerfindahl = 1.0 / Double(Sector.allCases.count - 1)  // Exclude unknown
        let diversificationScore = max(0, min(100, (1.0 - (herfindahlIndex - idealHerfindahl) / (1.0 - idealHerfindahl)) * 100))

        // Identify concentration risk
        let maxPercentage = sectorAllocations.first?.percentageOfPortfolio ?? 0
        let concentrationRisk: DiversificationAnalysis.ConcentrationRisk
        if maxPercentage > 50 {
            concentrationRisk = .high
        } else if maxPercentage > 25 {
            concentrationRisk = .medium
        } else {
            concentrationRisk = .low
        }

        // Find top-heavy sectors (>25% allocation)
        let topHeavySectors = sectorAllocations
            .filter { $0.percentageOfPortfolio > 25 }
            .map { $0.sector }

        // Generate recommendations
        var recommendations: [String] = []

        if topHeavySectors.count > 0 {
            for sector in topHeavySectors {
                recommendations.append("Consider reducing exposure to \(sector.displayName) (>\(String(format: "%.1f", sectorAllocations.first { $0.sector == sector }?.percentageOfPortfolio ?? 0))%)")
            }
        }

        // Suggest underrepresented sectors
        let representedSectors = Set(sectorAllocations.map { $0.sector })
        let missingMajorSectors = [Sector.technology, .healthcare, .financials, .consumerCyclical]
            .filter { !representedSectors.contains($0) }

        if missingMajorSectors.count > 0 {
            recommendations.append("Consider adding exposure to: \(missingMajorSectors.map { $0.displayName }.joined(separator: ", "))")
        }

        if diversificationScore > 70 {
            recommendations.append("Portfolio is well diversified across sectors")
        }

        await Logger.shared.debug("📊 Diversification score: \(String(format: "%.1f", diversificationScore)), risk: \(concentrationRisk.rawValue)")

        return DiversificationAnalysis(
            score: diversificationScore,
            concentrationRisk: concentrationRisk,
            recommendations: recommendations,
            topHeavySectors: topHeavySectors
        )
    }

    // MARK: - Sector Performance

    /// Calculate sector performance metrics
    func calculateSectorPerformance(
        sectorAllocations: [SectorAllocation]
    ) async -> [SectorPerformance] {
        var performance: [SectorPerformance] = []

        for allocation in sectorAllocations {
            performance.append(SectorPerformance(
                sector: allocation.sector,
                totalReturn: allocation.dayChange,
                percentReturn: allocation.dayChangePercent,
                contribution: allocation.dayChange,  // Contribution to total portfolio return
                positionCount: allocation.positions.count
            ))
        }

        return performance.sorted { $0.percentReturn > $1.percentReturn }
    }

    struct SectorPerformance: Identifiable {
        let id = UUID()
        let sector: Sector
        let totalReturn: Double
        let percentReturn: Double
        let contribution: Double
        let positionCount: Int
    }
}
