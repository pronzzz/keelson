// Ed25519 signing for Keelson's GitHub auto-updater.
//
//   swift scripts/update_keys.swift generate        Creates ~/.config/keelson/update_signing_key (once) and prints the public key.
//   swift scripts/update_keys.swift public          Prints the public key for the existing private key.
//   swift scripts/update_keys.swift sign <file>     Prints the base64 signature of <file>.
//
// The private key is read from $KEELSON_UPDATE_PRIVATE_KEY (base64, used in CI) or from the key file.
// The public key lives in Resources/Info.plist under KSUpdatePublicKey.
import CryptoKit
import Foundation

let keyFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/keelson/update_signing_key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    var encoded = ProcessInfo.processInfo.environment["KEELSON_UPDATE_PRIVATE_KEY"] ?? ""
    if encoded.isEmpty, let data = try? String(contentsOf: keyFile, encoding: .utf8) {
        encoded = data
    }
    encoded = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: encoded),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key. Set KEELSON_UPDATE_PRIVATE_KEY or run `generate`.")
    }
    return key
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: update_keys.swift generate|public|sign <file>") }

switch args[1] {
case "generate":
    if FileManager.default.fileExists(atPath: keyFile.path) {
        print(loadPrivateKey().publicKey.rawRepresentation.base64EncodedString())
        FileHandle.standardError.write("Key already exists at \(keyFile.path)\n".data(using: .utf8)!)
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadPrivateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count >= 3 else { fail("usage: update_keys.swift sign <file>") }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let signature = try loadPrivateKey().signature(for: data)
    print(signature.base64EncodedString())
default:
    fail("unknown command \(args[1])")
}
