// 使用应用内公钥独立验证更新包，避免公私钥配置不匹配却发布不可安装的版本。
import CryptoKit
import Foundation

do {
    guard CommandLine.arguments.count == 4,
          let publicKey = Data(base64Encoded: CommandLine.arguments[2]),
          let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    guard key.isValidSignature(signature, for: archive) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    print("更新包签名与应用内公钥一致。")
} catch {
    // 不回显输入或密钥资料。
    FileHandle.standardError.write(Data("更新签名校验失败，发布已停止。\n".utf8))
    exit(1)
}
