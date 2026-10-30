// 릴리스 zip에 업데이트 서명(Ed25519)을 만듭니다. 앱은 AppUpdate.publicKey로 이 서명을 확인한 뒤에만 설치합니다.
//
//   KONGI_UPDATE_KEY=<base64 개인 키> swift scripts/sign-update.swift dist/Kongi.zip > dist/Kongi.zip.sig
//
// 개인 키는 저장소에 두지 않습니다 (GitHub Actions에서는 Secrets의 KONGI_UPDATE_KEY).
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let keyText = ProcessInfo.processInfo.environment["KONGI_UPDATE_KEY"],
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("usage: KONGI_UPDATE_KEY=<key> swift scripts/sign-update.swift <file>\n".utf8))
    exit(1)
}
let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(try key.signature(for: file).base64EncodedString())
