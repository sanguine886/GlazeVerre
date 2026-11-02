import Crypto
import Foundation
import NIOSSH

/// A stable, human-verifiable identifier of an SSH host key: the OpenSSH-style
/// SHA256 fingerprint over the key's wire-format blob (RFC 4253).
public struct HostKeyFingerprint: Equatable, Hashable, Codable, Sendable {
    public let algorithm: String
    public let sha256: String

    public init(algorithm: String, sha256: String) {
        self.algorithm = algorithm
        self.sha256 = sha256
    }

    /// Extracts the raw key bytes from an `NIOSSHPublicKey` and hashes the
    /// OpenSSH wire blob.
    ///
    /// swift-nio-ssh keeps key serialization internal, so the raw crypto key is
    /// recovered by reflection over `NIOSSHPublicKey`'s internal backing storage
    /// (ADR-0008 in docs/ARCHITECTURE.md). A guard test pins this extraction to
    /// known fingerprints; if the dependency's layout changes, CI fails loudly.
    public static func make(from key: NIOSSHPublicKey) throws -> HostKeyFingerprint {
        guard let payload = extractPayload(from: key) else {
            throw SSHError.hostKeyUnsupported("Host key algorithm is not fingerprintable (RSA/custom/certified keys are not yet supported)")
        }

        var wire: [UInt8] = []
        switch payload {
        case let .ed25519(raw):
            appendSSHString(Array("ssh-ed25519".utf8), to: &wire)
            appendSSHString(Array(raw), to: &wire)
        case let .ecdsa(algorithm, curve, point):
            // RFC 5656 §3.1: the blob is `string(algorithm) + string(curve) +
            // string(Q)` — OpenSSH fingerprints hash this exact blob.
            appendSSHString(Array(algorithm.utf8), to: &wire)
            appendSSHString(Array(curve.utf8), to: &wire)
            appendSSHString(Array(point), to: &wire)
        }

        let digest = SHA256.hash(data: Data(wire))
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return HostKeyFingerprint(algorithm: payload.algorithmName, sha256: "SHA256:\(base64)")
    }

    enum KeyPayload {
        case ed25519(Data)
        case ecdsa(algorithm: String, curve: String, point: Data)

        var algorithmName: String {
            switch self {
            case .ed25519: "ssh-ed25519"
            case let .ecdsa(algorithm, _, _): algorithm
            }
        }
    }

    /// Reads the internal `backingKey` enum of `NIOSSHPublicKey`. Layout is
    /// pinned by HostKeyFingerprintTests against real fingerprints.
    static func extractPayload(from key: NIOSSHPublicKey) -> KeyPayload? {
        let keyMirror = Mirror(reflecting: key)
        guard let backing = keyMirror.children.first(where: { $0.label == "backingKey" })?.value,
              let payload = Mirror(reflecting: backing).children.first,
              let caseName = payload.label
        else {
            return nil
        }

        switch caseName {
        case "ed25519":
            guard let publicKey = payload.value as? Curve25519.Signing.PublicKey else { return nil }
            return .ed25519(publicKey.rawRepresentation)
        case "ecdsaP256":
            guard let publicKey = payload.value as? P256.Signing.PublicKey else { return nil }
            // rawRepresentation is the bare X||Y (64B); OpenSSH hashes the
            // SEC1 uncompressed point 0x04||X||Y, so use x963Representation.
            return .ecdsa(algorithm: "ecdsa-sha2-nistp256", curve: "nistp256", point: publicKey.x963Representation)
        case "ecdsaP384":
            guard let publicKey = payload.value as? P384.Signing.PublicKey else { return nil }
            return .ecdsa(algorithm: "ecdsa-sha2-nistp384", curve: "nistp384", point: publicKey.x963Representation)
        case "ecdsaP521":
            guard let publicKey = payload.value as? P521.Signing.PublicKey else { return nil }
            return .ecdsa(algorithm: "ecdsa-sha2-nistp521", curve: "nistp521", point: publicKey.x963Representation)
        default:
            return nil
        }
    }

    private static func appendSSHString(_ bytes: [UInt8], to buffer: inout [UInt8]) {
        let length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: length) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: bytes)
    }
}
