import Foundation

// 必须有 @objc 和 NSObject
@objc(WfmCameraPlugin)
public class WfmCameraPlugin: NSObject {
    
    // 必须添加 @objc 让 OC 能调用
    @objc public override init() {
        super.init()
        NSLog("✅ WfmCameraPlugin init")
    }
    
    // 方法必须添加 @objc
    @objc public func test(_ callback: @escaping ([String: Any]) -> Void) {
        NSLog("✅ test called")
        callback([
            "success": true,
            "msg": "工作正常"
        ])
    }
}
