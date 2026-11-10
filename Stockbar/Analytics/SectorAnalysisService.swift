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

        /// Get sector for a given symbol using known mappings.
        ///
        /// UK listings are keyed with their `.L` suffix (`TSCO.L`) so they cannot collide
        /// with US tickers that share the same letters (`TSCO` is Tractor Supply). `.LON`
        /// and `.XC` suffixes are normalised to `.L`. A bare ticker only ever matches the
        /// US table; an unmapped symbol is `.unknown`.
        static func forSymbol(_ symbol: String) -> Sector {
            let key = normalizedLookupKey(symbol)
            return sectorMap[key] ?? .unknown
        }

        /// Upper-cased lookup key with UK exchange suffixes normalised to `.L`.
        static func normalizedLookupKey(_ symbol: String) -> String {
            let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            for suffix in [".LON", ".XC"] where upper.hasSuffix(suffix) {
                return String(upper.dropLast(suffix.count)) + ".L"
            }
            return upper
        }

        // Stock sector mappings. US tickers are bare; UK tickers carry `.L`.
        private static let sectorMap: [String: Sector] = [
            // ===== US STOCKS =====

            // Technology
            "AAPL": .technology, "MSFT": .technology, "GOOGL": .technology, "GOOG": .technology,
            "AMZN": .consumerCyclical, "META": .communicationServices, "NVDA": .technology,
            "TSLA": .consumerCyclical, "AVGO": .technology, "ORCL": .technology,
            "CRM": .technology, "ADBE": .technology, "CSCO": .technology, "INTC": .technology,
            "AMD": .technology, "QCOM": .technology, "IBM": .technology, "NOW": .technology,
            "SNOW": .technology, "PLTR": .technology, "NET": .technology, "CRWD": .technology,
            "ZS": .technology, "DDOG": .technology, "MDB": .technology, "WDAY": .technology,
            "MU": .technology,

            // Healthcare
            "JNJ": .healthcare, "UNH": .healthcare, "LLY": .healthcare, "PFE": .healthcare,
            "ABBV": .healthcare, "TMO": .healthcare, "MRK": .healthcare, "ABT": .healthcare,
            "DHR": .healthcare, "BMY": .healthcare, "AMGN": .healthcare, "CVS": .healthcare,
            "GILD": .healthcare, "VRTX": .healthcare, "ISRG": .healthcare, "REGN": .healthcare,
            "CI": .healthcare, "HUM": .healthcare, "BSX": .healthcare, "MDT": .healthcare,
            "HIMS": .healthcare, "OSCR": .healthcare, "SAGE": .healthcare,
            // Cybin (now HELP) and Definium Therapeutics (formerly MindMed, MNMD).
            "HELP": .healthcare, "CYBN": .healthcare, "DFTX": .healthcare, "MNMD": .healthcare,

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
            "TSCO": .consumerCyclical, // Tractor Supply (UK Tesco is TSCO.L)
            "BABA": .consumerCyclical, "JD": .consumerCyclical,

            // Consumer Defensive
            "WMT": .consumerDefensive, "PG": .consumerDefensive, "KO": .consumerDefensive,
            "PEP": .consumerDefensive, "COST": .consumerDefensive, "PM": .consumerDefensive,
            "MO": .consumerDefensive, "CL": .consumerDefensive, "KMB": .consumerDefensive,
            "GIS": .consumerDefensive, "K": .consumerDefensive, "HSY": .consumerDefensive,

            // Energy
            "XOM": .energy, "CVX": .energy, "COP": .energy, "SLB": .energy, "EOG": .energy,
            "MPC": .energy, "PSX": .energy, "VLO": .energy, "OXY": .energy, "HAL": .energy,
            "BP": .energy,

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
            "RIO": .basicMaterials,

            // ===== UK STOCKS (FTSE 100/250, keyed with .L) =====

            // Technology
            "SGE.L": .technology, // Sage Group
            "DARK.L": .technology,
            "SMSD.L": .technology, // Samsung Electronics GDR

            // Healthcare
            "AZN.L": .healthcare, "GSK.L": .healthcare, "HIK.L": .healthcare, "SN.L": .healthcare,

            // Financials
            "LLOY.L": .financials, "BARC.L": .financials, "NWG.L": .financials, "STAN.L": .financials,
            "HSBA.L": .financials, "PRU.L": .financials, "AV.L": .financials, "AVIV.L": .financials,
            "LGEN.L": .financials, "III.L": .financials, "STJ.L": .financials, "LSEG.L": .financials,

            // Consumer Cyclical
            "MKS.L": .consumerCyclical, "WTB.L": .consumerCyclical, "JD.L": .consumerCyclical,
            "FRAS.L": .consumerCyclical, "NEXT.L": .consumerCyclical, "BDEV.L": .consumerCyclical,
            "PSON.L": .consumerCyclical, "BRBY.L": .consumerCyclical, "CPG.L": .consumerCyclical,
            "TW.L": .consumerCyclical, "PSN.L": .consumerCyclical, "SMWH.L": .consumerCyclical,
            "CARD.L": .consumerCyclical, // Card Factory

            // Consumer Defensive
            "TSCO.L": .consumerDefensive, "SBRY.L": .consumerDefensive, "OCDO.L": .consumerDefensive,
            "ULVR.L": .consumerDefensive, "DGE.L": .consumerDefensive, "ABF.L": .consumerDefensive,
            "RKT.L": .consumerDefensive, "IMB.L": .consumerDefensive, "BATS.L": .consumerDefensive,
            "CCH.L": .consumerDefensive,

            // Energy
            "BP.L": .energy, "SHEL.L": .energy, "RDSA.L": .energy, "RDSB.L": .energy,

            // Industrials
            "RR.L": .industrials, "IMI.L": .industrials,
            "SPX.L": .industrials, "WEIR.L": .industrials, "MGGT.L": .industrials,
            "IAG.L": .industrials, "EZJ.L": .industrials, "BNZL.L": .industrials,
            "EXPN.L": .industrials, "REL.L": .industrials, "RMG.L": .industrials,
            "BA.L": .industrials,

            // Communication Services
            "VOD.L": .communicationServices, "BT.A.L": .communicationServices, "ITV.L": .communicationServices,
            "AUTO.L": .communicationServices, "INF.L": .communicationServices, "WPP.L": .communicationServices,
            "AAF.L": .communicationServices, "RMV.L": .communicationServices,

            // Utilities
            "SSE.L": .utilities, "NG.L": .utilities, "UU.L": .utilities, "SVT.L": .utilities,

            // Real Estate
            "LAND.L": .realEstate, "SGRO.L": .realEstate, "BLND.L": .realEstate,
            "BBOX.L": .realEstate, "SAFE.L": .realEstate, "DIGS.L": .realEstate,

            // Basic Materials
            "RIO.L": .basicMaterials, "GLEN.L": .basicMaterials,
            "ANTO.L": .basicMaterials, "CRH.L": .basicMaterials, "JMAT.L": .basicMaterials,
            "COPG.L": .basicMaterials // Global X Copper Miners ETF
        ]
    }

    /// Diversification analysis
    struct DiversificationAnalysis {
        /// 0-100 (100 = perfectly diversified), computed over classified sectors only.
        let score: Double
        /// Whether the score is based on enough classified, finite, valued positions.
        let isAvailable: Bool
        let concentrationRisk: ConcentrationRisk
        let recommendations: [String]
        let topHeavySectors: [Sector]
        /// Share (0-100) of portfolio value in symbols with no known sector.
        let unclassifiedPercentage: Double

        /// Above this share the sector view says more about the lookup table than the portfolio.
        static let maximumUnclassifiedPercentage: Double = 50.0

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

        // Invalid values must never enter a portfolio total (NaN would poison every percentage).
        let validPositions = positions.filter { $0.value.isFinite && $0.value > 0 }
        let totalPortfolioValue = validPositions.values.reduce(0, +)
        guard totalPortfolioValue.isFinite, totalPortfolioValue > 0 else { return [] }

        // Group positions by sector
        var sectorMap: [Sector: (value: Double, change: Double, positions: [PositionSummary])] = [:]

        for (symbol, value) in validPositions {
            let sector = Sector.forSymbol(symbol)
            let change = dayChanges[symbol].flatMap { $0.isFinite ? $0 : nil } ?? 0.0

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
            let priorValue = data.value - data.change
            let changePercent = data.value > 0 && priorValue.isFinite && priorValue > 0
                ? (data.change / priorValue) * 100
                : 0

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

    /// Analyze portfolio diversification across sectors.
    ///
    /// The `.unknown` bucket is not a sector: it is excluded from the Herfindahl score,
    /// concentration and recommendations and reported as `unclassifiedPercentage`. When
    /// most of the portfolio is unclassified the analysis is marked unavailable.
    func analyzeDiversification(
        sectorAllocations: [SectorAllocation]
    ) async -> DiversificationAnalysis {
        await Logger.shared.debug("📊 Analyzing sector diversification")

        let totalValue = sectorAllocations.reduce(0.0) { $0 + $1.totalValue }
        guard totalValue.isFinite, totalValue > 0 else {
            return DiversificationAnalysis(
                score: .nan,
                isAvailable: false,
                concentrationRisk: .low,
                recommendations: [],
                topHeavySectors: [],
                unclassifiedPercentage: 0
            )
        }

        let classified = sectorAllocations.filter { $0.sector != .unknown }
        let classifiedValue = classified.reduce(0.0) { $0 + $1.totalValue }
        let unclassifiedPercentage = max(0, min(100, (1 - classifiedValue / totalValue) * 100))

        guard classifiedValue > 0,
              unclassifiedPercentage <= DiversificationAnalysis.maximumUnclassifiedPercentage else {
            return DiversificationAnalysis(
                score: .nan,
                isAvailable: false,
                concentrationRisk: .low,
                recommendations: [],
                topHeavySectors: [],
                unclassifiedPercentage: unclassifiedPercentage
            )
        }

        // Herfindahl index over classified sectors only.
        let herfindahlIndex = classified.reduce(0.0) { sum, allocation in
            let weight = allocation.totalValue / classifiedValue
            return sum + (weight * weight)
        }

        // Diversification score (inverse of concentration)
        // Perfect diversification (equal weights across 11 sectors) = 1/11 ≈ 0.091
        // Maximum concentration (100% in 1 sector) = 1.0
        let idealHerfindahl = 1.0 / Double(Sector.allCases.count - 1)  // Exclude unknown
        let diversificationScore = max(0, min(100, (1.0 - (herfindahlIndex - idealHerfindahl) / (1.0 - idealHerfindahl)) * 100))

        // Share of the classified portfolio held by each sector.
        func classifiedShare(_ allocation: SectorAllocation) -> Double {
            allocation.totalValue / classifiedValue * 100
        }

        let maxPercentage = classified.map(classifiedShare).max() ?? 0
        let concentrationRisk: DiversificationAnalysis.ConcentrationRisk
        if maxPercentage > 50 {
            concentrationRisk = .high
        } else if maxPercentage > 25 {
            concentrationRisk = .medium
        } else {
            concentrationRisk = .low
        }

        // Find top-heavy sectors (>25% of classified value)
        let topHeavy = classified.filter { classifiedShare($0) > 25 }
        let topHeavySectors = topHeavy.map { $0.sector }

        // Generate recommendations
        var recommendations: [String] = []

        for allocation in topHeavy {
            recommendations.append("Consider reducing exposure to \(allocation.sector.displayName) (>\(String(format: "%.1f", classifiedShare(allocation)))%)")
        }

        // Suggest underrepresented sectors
        let representedSectors = Set(classified.map { $0.sector })
        let missingMajorSectors = [Sector.technology, .healthcare, .financials, .consumerCyclical]
            .filter { !representedSectors.contains($0) }

        if !missingMajorSectors.isEmpty {
            recommendations.append("Consider adding exposure to: \(missingMajorSectors.map { $0.displayName }.joined(separator: ", "))")
        }

        if diversificationScore > 70 {
            recommendations.append("Portfolio is well diversified across sectors")
        }

        await Logger.shared.debug("📊 Diversification score: \(String(format: "%.1f", diversificationScore)), risk: \(concentrationRisk.rawValue), unclassified \(String(format: "%.1f", unclassifiedPercentage))%")

        return DiversificationAnalysis(
            score: diversificationScore,
            isAvailable: true,
            concentrationRisk: concentrationRisk,
            recommendations: recommendations,
            topHeavySectors: topHeavySectors,
            unclassifiedPercentage: unclassifiedPercentage
        )
    }
}
