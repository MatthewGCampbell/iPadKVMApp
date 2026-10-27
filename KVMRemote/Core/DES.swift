#if canImport(CommonCrypto)
import Foundation
import CommonCrypto

/// DES-ECB, used only for the legacy VNC password challenge.
func desEncrypt(_ data: Data, key: [UInt8]) -> Data? {
    var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeDES)
    var moved = 0
    let status = data.withUnsafeBytes { input in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                key, kCCKeySizeDES, nil,
                input.baseAddress, data.count,
                &out, out.count, &moved)
    }
    guard status == kCCSuccess else { return nil }
    return Data(out.prefix(moved))
}
#endif
