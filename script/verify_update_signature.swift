// Checks an update archive's EdDSA signature against a public key: the check
// the updater makes before it installs anything. script/sign_release.sh runs
// this with the key built into the app, so an archive signed with any other
// key is never listed in the feed.
//
//   swift script/verify_update_signature.swift <archive> <signature> <public key>
//
// The signature and the key are base64, as they appear in the feed and in
// the app's Info.plist (SUPublicEDKey).
import CryptoKit
import Foundation

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("Usage: swift verify_update_signature.swift <archive> <signature> <public key>", status: 64)
}
guard let archive = FileManager.default.contents(atPath: arguments[1]) else {
    fail("Cannot read \(arguments[1]).", status: 66)
}
guard let signature = Data(base64Encoded: arguments[2]),
      let keyBytes = Data(base64Encoded: arguments[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
    fail("The signature or the public key is not valid base64 EdDSA data.", status: 65)
}
guard key.isValidSignature(signature, for: archive) else {
    fail("The archive's signature does not match the app's update key (SUPublicEDKey).", status: 1)
}
print("The archive's signature matches the app's update key.")
