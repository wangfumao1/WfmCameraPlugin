import Foundation
import UIKit

@objc public class WfmCameraPlugin: NSObject {
    
    @objc public override init() {
        super.init()
        print("WfmCameraPlugin 初始化成功")
    }
    
    @objc public func test(_ callback: Any?) {
        print("test 方法被调用")
        
        if let cb = callback as? ([String: Any]) -> Void {
            cb(["success": true, "msg": "插件工作正常"])
        }
    }
    
    @objc public func checkCameraPermission(_ callback: Any?) {
        // 简单的测试方法
        if let cb = callback as? ([String: Any]) -> Void {
            cb(["success": true, "status": "authorized"])
        }
    }
}
