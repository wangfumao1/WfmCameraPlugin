import UIKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// UniApp 原生插件协议定义
@objc public protocol UniModule {
    var uni: UniModuleContext! { get set }
    func initPlugin(_ moduleContext: UniModuleContext)
}

@objc public class UniModuleContext: NSObject {
    public override init() {
        super.init()
    }
}

@objc public class UniCallback: NSObject {
    private var callback: (([String: Any]) -> Void)?
    
    @objc public init(callback: @escaping ([String: Any]) -> Void) {
        self.callback = callback
        super.init()
    }
    
    @objc public func callAsFunction(_ data: [String: Any]) {
        callback?(data)
    }
}

@objcMembers public class WfmCameraPlugin: NSObject, UniModule, AVCapturePhotoCaptureDelegate {
    
    public var uni: UniModuleContext!
    
    // 摄像头会话
    private var multiCamSession: AVCaptureMultiCamSession?
    private var backCamera: AVCaptureDevice?
    private var frontCamera: AVCaptureDevice?
    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    private var photoOutput: AVCapturePhotoOutput?
    
    // 预览图层
    private var backPreviewLayer: AVCaptureVideoPreviewLayer?
    private var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    
    // 拍照回调
    private var photoCallback: UniCallback?
    
    // 当前拍照计数
    private var photoCount = 0
    private var expectedPhotos = 2 // 前后各一张
    private var frontPhotoPath: String?
    private var backPhotoPath: String?
    
    // MARK: - 初始化插件
    public func initPlugin(_ moduleContext: UniModuleContext) {
        uni = moduleContext
        print("【WfmCameraPlugin】初始化完成")
    }
    
    // MARK: - 权限检查
    public func checkCameraPermission(_ callback: UniCallback?) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var result: [String: Any] = [
            "success": status == .authorized,
            "status": String(describing: status)
        ]
        
        if status == .notDetermined {
            // 请求权限
            AVCaptureDevice.requestAccess(for: .video) { granted in
                result["success"] = granted
                result["status"] = granted ? "authorized" : "denied"
                callback?(result)
            }
        } else {
            callback?(result)
        }
    }
    
    // MARK: - 打开双摄
    public func openDualCamera(_ params: [String: Any]?, _ callback: UniCallback?) {
        guard #available(iOS 13.0, *) else {
            callback?(["success": false, "msg": "仅支持 iOS 13+ 设备"])
            return
        }
        
        // 检查权限
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            callback?(["success": false, "msg": "没有相机权限，请先授权"])
            return
        }
        
        // 初始化双摄会话
        if setupMultiCameraSession() {
            callback?(["success": true, "msg": "双摄已启动"])
        } else {
            callback?(["success": false, "msg": "双摄启动失败，设备可能不支持"])
        }
    }
    
    // MARK: - 设置双摄
    private func setupMultiCameraSession() -> Bool {
        guard #available(iOS 13.0, *) else { return false }
        
        // 1. 创建多摄会话
        let session = AVCaptureMultiCamSession()
        session.sessionPreset = .photo
        self.multiCamSession = session
        
        // 2. 获取前后摄像头
        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            print("【错误】不支持双摄像头设备")
            return false
        }
        backCamera = back
        frontCamera = front
        
        // 3. 添加后置摄像头输入
        do {
            let backInput = try AVCaptureDeviceInput(device: back)
            if session.canAddInput(backInput) {
                session.addInput(backInput)
                self.backInput = backInput
            }
            
            let frontInput = try AVCaptureDeviceInput(device: front)
            if session.canAddInput(frontInput) {
                session.addInput(frontInput)
                self.frontInput = frontInput
            }
        } catch {
            print("【错误】添加摄像头输入失败：\(error)")
            return false
        }
        
        // 4. 添加拍照输出
        let photoOutput = AVCapturePhotoOutput()
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            self.photoOutput = photoOutput
        }
        
        // 5. 启动会话
        session.startRunning()
        
        return session.isRunning
    }
    
    // MARK: - 创建预览图层（返回给前端显示）
    public func createPreviewLayers(_ params: [String: Any]?, _ callback: UniCallback?) {
        guard let session = multiCamSession, session.isRunning else {
            callback?(["success": false, "msg": "摄像头未启动"])
            return
        }
        
        // 这里返回预览图层的配置信息，前端需要用 cover-view 或 plus.webview 来显示
        callback?([
            "success": true,
            "msg": "预览图层已创建，请使用原生 cover-view 显示"
        ])
    }
    
    // MARK: - 拍照
    public func takePhoto(_ params: [String: Any]?, _ callback: UniCallback?) {
        guard let photoOutput = photoOutput else {
            callback?(["success": false, "msg": "拍照输出未初始化"])
            return
        }
        
        // 重置状态
        photoCount = 0
        frontPhotoPath = nil
        backPhotoPath = nil
        photoCallback = callback
        
        // 拍照设置
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        
        // 前后各拍一张（AVCaptureMultiCamSession 会自动处理）
        photoOutput.capturePhoto(with: settings, delegate: self)
        
        // 注意：AVCapturePhotoCaptureDelegate 的代理方法会被调用两次
        // 因为有两个摄像头输入
    }
    
    // MARK: - AVCapturePhotoCaptureDelegate
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("拍照失败：\(error)")
            return
        }
        
        // 获取图片数据
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            return
        }
        
        // 保存到临时目录
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "photo_\(timestamp)_\(photoCount).jpg"
        let filePath = NSTemporaryDirectory() + fileName
        
        if let jpegData = image.jpegData(compressionQuality: 0.9) {
            try? jpegData.write(to: URL(fileURLWithPath: filePath))
        }
        
        // 判断是前摄还是后摄
        // 这里简单通过照片尺寸或位置判断，实际可能需要更复杂的识别
        if photoCount == 0 {
            backPhotoPath = filePath
        } else {
            frontPhotoPath = filePath
        }
        
        photoCount += 1
        
        // 两张都拍完了，回调结果
        if photoCount >= expectedPhotos {
            let result: [String: Any] = [
                "success": true,
                "frontPath": frontPhotoPath ?? "",
                "backPath": backPhotoPath ?? "",
                "msg": "拍照完成"
            ]
            photoCallback?(result)
        }
    }
    
    // MARK: - 关闭双摄
    public func closeDualCamera(_ params: [String: Any]?, _ callback: UniCallback?) {
        multiCamSession?.stopRunning()
        multiCamSession = nil
        backInput = nil
        frontInput = nil
        photoOutput = nil
        
        callback?(["success": true, "msg": "摄像头已关闭"])
    }
}
