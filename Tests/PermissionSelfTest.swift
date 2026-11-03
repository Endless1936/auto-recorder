import Foundation
import ScreenCaptureKit

enum PermissionSelfTest {
    static func run() throws {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let wrapped = NSError(domain: "LocalRecorder", code: 1, userInfo: [NSUnderlyingErrorKey: declined])
        let disk = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let internalCapture = NSError(domain: SCStreamErrorDomain, code: -3811)
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: declined.code)
        guard RecorderError.isScreenAuthorization(RecorderError.screenAuthorization),
              RecorderError.isScreenAuthorization(declined),
              RecorderError.isScreenAuthorization(wrapped),
              !RecorderError.isScreenAuthorization(disk),
              !RecorderError.isScreenAuthorization(internalCapture),
              !RecorderError.isScreenAuthorization(unrelated),
              !RecorderError.isScreenAuthorization(RecorderError.message("无法保存文件")) else {
            throw RecorderError.message("授权错误分类测试失败。")
        }
        print("PASS permission errors: explicit and wrapped TCC denial recognized; disk/internal/unrelated errors preserved")
    }
}
