import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Errors a settings export or import reports to the user. Messages never
/// include secrets, file contents or passwords.
enum SettingsTransferError: Error, Equatable, LocalizedError {
    case passwordTooShort
    case notAnExportFile
    case newerFormatVersion(Int)
    case damagedFile
    case wrongPasswordOrDamaged
    case unsupportedContents(String)
    case incompatibleDatabase
    case damagedDatabase
    case databaseUnavailable
    case credentialUnreadable(String)
    case backupFailed(String)
    case applyFailed
    case applyFailedPartlyRestored(includesDatabase: Bool)
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            return "Use a password of at least \(SettingsTransferContainer.minimumPasswordLength) characters."
        case .notAnExportFile:
            return "This isn't a Stockbar export file."
        case .newerFormatVersion:
            return "This export was made by a newer version of Stockbar. Update Stockbar, then try again."
        case .damagedFile:
            return "This file is damaged or incomplete."
        case .wrongPasswordOrDamaged:
            return "Wrong password, or the file is damaged."
        case .unsupportedContents(let detail):
            return "This export can't be imported: \(detail)"
        case .incompatibleDatabase:
            return "The portfolio database in this export was made by a different version of Stockbar, so it can't be imported here. Nothing was changed."
        case .damagedDatabase:
            return "The portfolio database in this export is damaged. Nothing was changed."
        case .databaseUnavailable:
            return "Stockbar's portfolio database isn't available, so Everything can't be exported or imported."
        case .credentialUnreadable(let name):
            return "Stockbar couldn't read the \(name) from the Keychain. Nothing was changed."
        case .backupFailed(let detail):
            return "Stockbar couldn't back up your current data, so nothing was imported. \(detail)"
        case .applyFailed:
            return "The import failed, so Stockbar put your previous settings and data back."
        case .applyFailedPartlyRestored(let includesDatabase):
            return includesDatabase
                ? "The import failed and Stockbar couldn't put everything back. A safety copy of your portfolio database is in StoreRecovery. Quit Stockbar before restoring it."
                : "The import failed and Stockbar couldn't put everything back. Check your settings and keys in Settings."
        case .keyDerivationFailed:
            return "Stockbar couldn't derive an encryption key from the password."
        }
    }
}

/// The encrypted `.stockbarexport` container.
///
/// Layout (all integers big-endian):
///
///     magic        14 bytes  "STOCKBAREXPORT"
///     version      UInt16    format version, currently 1
///     kdf          UInt8     1 = PBKDF2-HMAC-SHA256
///     iterations   UInt32    PBKDF2 rounds (at least 600,000)
///     saltLength   UInt8     then the salt
///     nonceLength  UInt8     then the AES-GCM nonce (12 bytes)
///     ciphertext   …         AES-256-GCM ciphertext followed by its 16-byte tag
///
/// Every byte before the ciphertext is passed to AES-GCM as additional
/// authenticated data, so changing the version, iteration count, salt or nonce
/// fails authentication just like changing the ciphertext.
enum SettingsTransferContainer {
    static let fileExtension = "stockbarexport"
    static let magic = Data("STOCKBAREXPORT".utf8)
    static let formatVersion: UInt16 = 1
    static let minimumPasswordLength = 8
    static let defaultIterations: UInt32 = 600_000
    static let minimumIterations: UInt32 = 600_000
    /// Upper bound accepted when reading, so a damaged header cannot make
    /// key derivation run for minutes.
    static let maximumIterations: UInt32 = 10_000_000
    static let saltLength = 32

    private static let kdfPBKDF2SHA256: UInt8 = 1
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let keyLength = 32

    /// Encrypts `plaintext` with a key derived from `password`.
    static func seal(_ plaintext: Data, password: String, iterations: UInt32 = defaultIterations) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw SettingsTransferError.passwordTooShort }
        let salt = try randomBytes(count: saltLength)
        let nonce = AES.GCM.Nonce()
        var header = magic
        append(formatVersion, to: &header)
        header.append(kdfPBKDF2SHA256)
        append(iterations, to: &header)
        header.append(UInt8(salt.count))
        header.append(salt)
        header.append(UInt8(nonceLength))
        nonce.withUnsafeBytes { header.append(contentsOf: $0) }

        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
        var output = header
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    /// Checks the magic string and format version without a password, so the
    /// user hears about a wrong or newer file before typing one.
    static func validateHeader(_ data: Data) throws {
        _ = try parse(data)
    }

    /// Authenticates and decrypts a container. Throws `wrongPasswordOrDamaged`
    /// for a wrong password or any change to the file.
    static func open(_ data: Data, password: String) throws -> Data {
        let parsed = try parse(data)
        let key = try deriveKey(password: password, salt: parsed.salt, iterations: parsed.iterations)
        do {
            let box = try AES.GCM.SealedBox(nonce: parsed.nonce, ciphertext: parsed.ciphertext, tag: parsed.tag)
            return try AES.GCM.open(box, using: key, authenticating: parsed.header)
        } catch {
            throw SettingsTransferError.wrongPasswordOrDamaged
        }
    }

    // MARK: - Parsing

    private struct ParsedContainer {
        let header: Data
        let iterations: UInt32
        let salt: Data
        let nonce: AES.GCM.Nonce
        let ciphertext: Data
        let tag: Data
    }

    private static func parse(_ data: Data) throws -> ParsedContainer {
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count, Data(bytes[0..<magic.count]) == magic else {
            throw SettingsTransferError.notAnExportFile
        }
        var reader = ByteReader(bytes: bytes, offset: magic.count)
        let version = try reader.readUInt16()
        guard version != 0 else { throw SettingsTransferError.damagedFile }
        guard version <= formatVersion else { throw SettingsTransferError.newerFormatVersion(Int(version)) }

        guard try reader.readUInt8() == kdfPBKDF2SHA256 else { throw SettingsTransferError.damagedFile }
        let iterations = try reader.readUInt32()
        guard (minimumIterations...maximumIterations).contains(iterations) else {
            throw SettingsTransferError.damagedFile
        }
        let saltCount = Int(try reader.readUInt8())
        guard (16...64).contains(saltCount) else { throw SettingsTransferError.damagedFile }
        let salt = try reader.read(count: saltCount)
        guard Int(try reader.readUInt8()) == nonceLength else { throw SettingsTransferError.damagedFile }
        let nonceBytes = try reader.read(count: nonceLength)
        let headerEnd = reader.offset
        guard bytes.count - headerEnd >= tagLength else { throw SettingsTransferError.damagedFile }

        let tagStart = bytes.count - tagLength
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes) else { throw SettingsTransferError.damagedFile }
        return ParsedContainer(
            header: Data(bytes[0..<headerEnd]),
            iterations: iterations,
            salt: salt,
            nonce: nonce,
            ciphertext: Data(bytes[headerEnd..<tagStart]),
            tag: Data(bytes[tagStart...])
        )
    }

    private struct ByteReader {
        let bytes: [UInt8]
        var offset: Int

        mutating func read(count: Int) throws -> Data {
            guard count >= 0, offset + count <= bytes.count else { throw SettingsTransferError.damagedFile }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }

        mutating func readUInt8() throws -> UInt8 {
            try read(count: 1)[0]
        }

        mutating func readUInt16() throws -> UInt16 {
            try read(count: 2).reduce(0) { ($0 << 8) | UInt16($1) }
        }

        mutating func readUInt32() throws -> UInt32 {
            try read(count: 4).reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }

    // MARK: - Crypto helpers

    /// PBKDF2-HMAC-SHA256. The password is normalised (NFC) so the same
    /// characters typed with a different input method derive the same key.
    /// Intermediate buffers are zeroed before returning.
    static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        defer {
            wipe(&passwordBytes)
            wipe(&derived)
        }
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordChars.baseAddress,
                        passwordChars.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        &derived,
                        derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SettingsTransferError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw SettingsTransferError.keyDerivationFailed }
        return Data(bytes)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

extension Data {
    /// Overwrites the bytes in place where this value owns its buffer. Used to
    /// drop decrypted or about-to-be-encrypted payloads promptly.
    mutating func zeroBytes() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
    }
}
