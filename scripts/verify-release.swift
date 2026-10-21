#!/usr/bin/swift
import CryptoKit
import Foundation

// Verify with the public key actually embedded in the distributable app. This
// catches a CI secret that signs successfully but belongs to a different app.
struct VerificationError: Error, CustomStringConvertible {
    let description: String
}
func verifyRelease() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 else {
        throw VerificationError(description: "Usage: verify-release.swift app.plist appcast.xml archive.zip")
    }
    let plistData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    guard let text = plist?["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: text), keyData.count == 32 else {
        throw VerificationError(description: "アプリの公開鍵が不正です。")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[2]), options: .nodeLoadExternalEntitiesNever)
    let enclosures = try xml.nodes(forXPath: "//enclosure")
    guard enclosures.count == 1, let enclosure = enclosures.first as? XMLElement,
          let signatureText = enclosure.attributes?.first(where: { $0.localName == "edSignature" })?.stringValue,
          let signature = Data(base64Encoded: signatureText),
          let lengthText = enclosure.attribute(forName: "length")?.stringValue else {
        throw VerificationError(description: "appcast の署名またはファイル情報が不正です。")
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
    guard Int(lengthText) == archive.count, key.isValidSignature(signature, for: archive) else {
        throw VerificationError(description: "配布ファイルの署名がアプリ内の公開鍵と一致しません。")
    }
    print("署名と配布アプリ内の公開鍵が一致しました。")
}
do { try verifyRelease() }
catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
