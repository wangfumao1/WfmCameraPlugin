//
//  WfmCameraPlugin.m
//  修复 iPhone XS Max 双摄画面不显示问题 + 异常降级处理
//

#import "WfmCameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

// 在文件顶部添加头文件
#import "PDRCoreApp.h"
#import "PDRCoreAppManager.h"
#import "PDRCoreAppInfo.h"

// 错误码定义
typedef NS_ENUM(NSInteger, WfmCameraErrorCode) {
    WfmCameraErrorUnsupportedOS = 1001,           // iOS 版本不支持
    WfmCameraErrorCameraPermissionDenied = 1002,   // 相机权限被拒绝
    WfmCameraErrorPhotoPermissionDenied = 1003,    // 相册权限被拒绝
    WfmCameraErrorCameraUnavailable = 1004,        // 找不到摄像头
    WfmCameraErrorUserCancel = 1005,               // 用户取消
    WfmCameraErrorCaptureFailed = 1006,            // 拍照失败
    WfmCameraErrorSaveFailed = 1007,               // 保存失败
    WfmCameraErrorSetupFailed = 1008,              // 初始化失败
    WfmCameraErrorMultiCamNotSupported = 1009,     // 不支持双摄
    WfmCameraErrorNoVideoOutput = 1010             // 无视频输出（画面不显示）
};

// 错误类型字符串
static NSString *const kErrorTypeUnsupportedOS = @"unsupported_os";
static NSString *const kErrorTypeCameraPermissionDenied = @"camera_permission_denied";
static NSString *const kErrorTypePhotoPermissionDenied = @"photo_permission_denied";
static NSString *const kErrorTypeCameraUnavailable = @"camera_unavailable";
static NSString *const kErrorTypeUserCancel = @"user_cancel";
static NSString *const kErrorTypeCaptureFailed = @"capture_failed";
static NSString *const kErrorTypeSaveFailed = @"save_failed";
static NSString *const kErrorTypeSetupFailed = @"setup_failed";
static NSString *const kErrorTypeMultiCamNotSupported = @"multicam_not_supported";
static NSString *const kErrorTypeNoVideoOutput = @"no_video_output";

@interface WfmCameraPlugin () <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureMultiCamSession *multiCamSession;
@property (nonatomic, strong) AVCaptureDeviceInput *backInput;
@property (nonatomic, strong) AVCaptureDeviceInput *frontInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *backOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *frontOutput;
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, strong) UIView *frontPreviewView;
@property (nonatomic, strong) UIImageView *backImageView;
@property (nonatomic, strong) UIImageView *frontImageView;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, assign) CGColorSpaceRef colorSpace;
@property (nonatomic, strong) NSMutableArray *logs;
@property (nonatomic, strong) UniModuleKeepAliveCallback currentCallback;

// UI 控件
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *captureButton;

// 拍照相关
@property (nonatomic, strong) UIImage *backImage;
@property (nonatomic, strong) UIImage *frontImage;
@property (nonatomic, assign) BOOL waitingForBackPhoto;
@property (nonatomic, assign) BOOL waitingForFrontPhoto;
@property (nonatomic, assign) BOOL isTakingPhoto;

// 水印相关
@property (nonatomic, strong) NSString *watermarkLocation;
@property (nonatomic, strong) NSString *watermarkLatitude;
@property (nonatomic, strong) NSString *watermarkLongitude;
@property (nonatomic, strong) NSString *watermarkOperator;

// 画面检测相关
@property (nonatomic, strong) NSTimer *videoOutputCheckTimer;
@property (nonatomic, assign) BOOL hasReceivedBackFrame;
@property (nonatomic, assign) BOOL hasReceivedFrontFrame;
@property (nonatomic, assign) BOOL hasReportedNoVideo;

// 摄像头格式相关方法
- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device;
- (BOOL)configureBestFormatForDevice:(AVCaptureDevice *)device;
- (BOOL)isMultiCamSupported;

@end

@implementation WfmCameraPlugin

UNI_EXPORT_METHOD(@selector(test:callback:))
UNI_EXPORT_METHOD(@selector(openDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(closeDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(log:callback:))

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoQueue = dispatch_queue_create("com.wfm.camera.queue", DISPATCH_QUEUE_SERIAL);
        _logs = [NSMutableArray array];
        _hasReceivedBackFrame = NO;
        _hasReceivedFrontFrame = NO;
        _hasReportedNoVideo = NO;
    }
    return self;
}

- (void)addLog:(NSString *)message {
    if (!self.logs) {
        self.logs = [NSMutableArray array];
    }
    [self.logs addObject:message];
    NSLog(@"[WfmCameraPlugin] %@", message);
}

// 发送错误回调
- (void)sendErrorWithCode:(WfmCameraErrorCode)code 
                      msg:(NSString *)msg 
                errorType:(NSString *)errorType 
                 callback:(UniModuleKeepAliveCallback)callback {
    if (callback) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"code"] = @(code);
        result[@"success"] = @NO;
        result[@"msg"] = msg;
        result[@"errorType"] = errorType;
        if (self.logs && self.logs.count > 0) {
            result[@"logs"] = [self.logs copy];
        }
        callback(result, NO);
    }
    if (self.logs) {
        [self.logs removeAllObjects];
    }
    self.currentCallback = nil;
    [self stopVideoOutputCheckTimer];
}

// 发送成功回调
- (void)sendSuccessWithBackPath:(NSString *)backPath 
                      frontPath:(NSString *)frontPath 
                       callback:(UniModuleKeepAliveCallback)callback {
    if (callback) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"code"] = @0;
        result[@"success"] = @YES;
        result[@"msg"] = @"拍照成功";
        
        NSMutableDictionary *data = [NSMutableDictionary dictionary];
        if (backPath) {
            data[@"backPath"] = backPath;
        }
        if (frontPath) {
            data[@"frontPath"] = frontPath;
        }
        result[@"data"] = data;
        
        if (self.logs && self.logs.count > 0) {
            result[@"logs"] = [self.logs copy];
        }
        callback(result, NO);
    }
    if (self.logs) {
        [self.logs removeAllObjects];
    }
    self.currentCallback = nil;
    [self stopVideoOutputCheckTimer];
}

// 发送普通结果（用于取消等）
- (void)sendResult:(BOOL)success message:(NSString *)message callback:(UniModuleKeepAliveCallback)callback {
    if (callback) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"success"] = @(success);
        if (message) {
            result[@"msg"] = message;
        }
        if (self.logs && self.logs.count > 0) {
            result[@"logs"] = [self.logs copy];
        }
        callback(result, NO);
    }
    if (self.logs) {
        [self.logs removeAllObjects];
    }
    self.currentCallback = nil;
    [self stopVideoOutputCheckTimer];
}

// 保存图片到 UniApp 可访问的路径
- (NSString *)saveImageToTempPath:(UIImage *)image withPrefix:(NSString *)prefix {
    // 获取 UniApp 主应用的 documentPath（对应 _doc/）
    PDRCoreAppInfo *appinfo = [PDRCore Instance].appManager.getMainAppInfo;
    NSString *docPath = appinfo.documentPath;
    
    // 创建相机子目录
    NSString *cameraDir = [docPath stringByAppendingPathComponent:@"camera"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cameraDir]) {
        [fileManager createDirectoryAtPath:cameraDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    // 生成唯一文件名
    long long milliseconds = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    int randomNum = arc4random_uniform(10000);
    NSString *fileName = [NSString stringWithFormat:@"%@_%lld_%d.jpg", prefix, milliseconds, randomNum];
    NSString *filePath = [cameraDir stringByAppendingPathComponent:fileName];
    
    // 保存图片
    NSData *imageData = UIImageJPEGRepresentation(image, 0.9);
    [imageData writeToFile:filePath atomically:YES];
    
    // 返回 UniApp 可访问的相对路径（_doc/camera/xxx.jpg）
    NSString *relativePath = [NSString stringWithFormat:@"_doc/camera/%@", fileName];
    
    [self addLog:[NSString stringWithFormat:@"照片已保存: %@", relativePath]];
    return relativePath;
}

- (void)log:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *message = options[@"message"] ?: @"";
    [self addLog:message];
    if (callback) {
        callback(@{@"success": @YES, @"log": message}, NO);
    }
}

- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    [self addLog:@"========== test 方法开始 =========="];
    [self addLog:@"测试第一条日志"];
    [self addLog:@"测试第二条日志"];
    [self addLog:@"测试第三条日志"];
    [self addLog:@"========== test 方法结束 =========="];
    [self sendResult:YES message:@"插件工作正常！" callback:callback];
}

#pragma mark - 检测是否支持双摄
- (BOOL)isMultiCamSupported API_AVAILABLE(ios(13.0)) {
    // 检查设备是否支持 MultiCam
    if (![AVCaptureMultiCamSession isMultiCamSupported]) {
        [self addLog:@"⚠️ 当前设备不支持 MultiCam"];
        return NO;
    }
    
    // 检查是否可以添加多路输出
    if (![AVCaptureMultiCamSession multiCamSessionSupportedForCameraPosition:AVCaptureDevicePositionBack] ||
        ![AVCaptureMultiCamSession multiCamSessionSupportedForCameraPosition:AVCaptureDevicePositionFront]) {
        [self addLog:@"⚠️ 设备不支持前后摄像头同时使用"];
        return NO;
    }
    
    [self addLog:@"✅ 设备支持双摄"];
    return YES;
}

#pragma mark - 画面输出检测
- (void)startVideoOutputCheckTimer {
    // 重置标志
    self.hasReceivedBackFrame = NO;
    self.hasReceivedFrontFrame = NO;
    self.hasReportedNoVideo = NO;
    
    // 3秒后检查是否有视频帧输出
    dispatch_async(dispatch_get_main_queue(), ^{
        self.videoOutputCheckTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                      target:self
                                                                    selector:@selector(checkVideoOutput)
                                                                    userInfo:nil
                                                                     repeats:NO];
    });
    [self addLog:@"启动视频输出检测定时器（3秒后检查）"];
}

- (void)stopVideoOutputCheckTimer {
    if (self.videoOutputCheckTimer) {
        [self.videoOutputCheckTimer invalidate];
        self.videoOutputCheckTimer = nil;
    }
}

- (void)checkVideoOutput {
    if (self.hasReportedNoVideo) {
        return;
    }
    
    BOOL hasIssue = NO;
    NSMutableString *issueMsg = [NSMutableString string];
    
    if (!self.hasReceivedBackFrame) {
        [issueMsg appendString:@"后置摄像头无画面输出; "];
        hasIssue = YES;
    }
    if (!self.hasReceivedFrontFrame) {
        [issueMsg appendString:@"前置摄像头无画面输出; "];
        hasIssue = YES;
    }
    
    if (hasIssue) {
        self.hasReportedNoVideo = YES;
        [self addLog:[NSString stringWithFormat:@"❌ 画面检测失败: %@", issueMsg]];
        
        // 关闭双摄并清理资源
        [self closeDualCameraAndCleanup];
        
        // 返回错误，让前端降级使用依次拍照
        [self sendErrorWithCode:WfmCameraErrorNoVideoOutput
                            msg:[NSString stringWithFormat:@"双摄画面加载失败: %@", issueMsg]
                      errorType:kErrorTypeNoVideoOutput
                       callback:self.currentCallback];
    } else {
        [self addLog:@"✅ 画面检测通过，前后摄像头均有画面输出"];
    }
}

#pragma mark - 获取摄像头当前分辨率
- (CGSize)getCameraResolution:(AVCaptureDevice *)device {
    if (!device || !device.activeFormat) {
        return CGSizeMake(1920, 1080);
    }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    return CGSizeMake(dims.width, dims.height);
}

- (void)openDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    self.currentCallback = callback;
    self.isTakingPhoto = NO;
    self.hasReceivedBackFrame = NO;
    self.hasReceivedFrontFrame = NO;
    self.hasReportedNoVideo = NO;
    
    // 解析水印相关参数
    self.watermarkLocation = options[@"location"] ?: @"";
    self.watermarkLatitude = options[@"latitude"] ?: @"";
    self.watermarkLongitude = options[@"longitude"] ?: @"";
    self.watermarkOperator = options[@"operator"] ?: @"";
    
    [self addLog:@"========== 打开双摄 =========="];
    [self addLog:[NSString stringWithFormat:@"水印参数: 地点=%@, 纬度=%@, 经度=%@, 操作人=%@", 
                 self.watermarkLocation, self.watermarkLatitude, self.watermarkLongitude, self.watermarkOperator]];
    
    @try {
        // 检查 iOS 版本
        if (@available(iOS 13.0, *)) {
            [self addLog:@"✅ iOS 13+ 检查通过"];
        } else {
            [self addLog:@"❌ 需要 iOS 13 或更高版本"];
            [self sendErrorWithCode:WfmCameraErrorUnsupportedOS 
                                msg:@"需要 iOS 13 或更高版本" 
                          errorType:kErrorTypeUnsupportedOS 
                           callback:callback];
            return;
        }
        
        // 检查硬件是否支持双摄
        if (![self isMultiCamSupported]) {
            [self addLog:@"❌ 当前设备不支持双摄功能"];
            [self sendErrorWithCode:WfmCameraErrorMultiCamNotSupported
                                msg:@"当前设备不支持双摄像头同时使用"
                          errorType:kErrorTypeMultiCamNotSupported
                           callback:callback];
            return;
        }
        
        // 检查相机权限
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        [self addLog:[NSString stringWithFormat:@"相机权限状态: %ld", (long)status]];
        
        if (status != AVAuthorizationStatusAuthorized) {
            if (status == AVAuthorizationStatusNotDetermined) {
                [self addLog:@"请求相机权限..."];
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) {
                            [self addLog:@"✅ 权限已授权"];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self setupDualCamera];
                            });
                        } else {
                            [self addLog:@"❌ 用户拒绝相机权限"];
                            [self sendErrorWithCode:WfmCameraErrorCameraPermissionDenied 
                                                msg:@"需要相机权限，请在设置中开启" 
                                          errorType:kErrorTypeCameraPermissionDenied 
                                           callback:callback];
                        }
                    });
                }];
            } else {
                [self addLog:@"❌ 相机权限未授权"];
                [self sendErrorWithCode:WfmCameraErrorCameraPermissionDenied 
                                    msg:@"相机权限未授权，请在设置中开启" 
                              errorType:kErrorTypeCameraPermissionDenied 
                               callback:callback];
            }
            return;
        }
        
        [self addLog:@"✅ 相机权限已授权"];
        [self setupDualCamera];
        
    } @catch (NSException *exception) {
        [self addLog:[NSString stringWithFormat:@"❌ 异常: %@", exception.reason]];
        [self sendErrorWithCode:WfmCameraErrorSetupFailed 
                            msg:exception.reason 
                      errorType:kErrorTypeSetupFailed 
                       callback:callback];
    }
}

- (void)setupDualCamera API_AVAILABLE(ios(13.0)) {
    [self addLog:@"开始设置双摄..."];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 创建 MultiCamSession
            self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
            
            // ========== 关键配置1: 启用多任务摄像头访问 ==========
            // 这个配置告诉系统：我的 App 需要在非前台活跃状态下也能保持摄像头运行
            // 某些机型（尤其是 XS Max）对资源管理更敏感，不配置这个可能导致画面被"优化"掉
            if (@available(iOS 13.0, *)) {
                self.multiCamSession.isMultitaskingCameraAccessEnabled = YES;
                [self addLog:@"✅ 已启用 isMultitaskingCameraAccessEnabled = YES"];
            }
            
            // 关键配置2: 设置会话预设为高画质
            if ([self.multiCamSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
                self.multiCamSession.sessionPreset = AVCaptureSessionPresetHigh;
                [self addLog:@"✅ 会话预设: High"];
            }
            
            // 关键配置3: 配置音频会话（避免被系统优化）
            self.multiCamSession.automaticallyConfiguresApplicationAudioSession = NO;
            self.multiCamSession.usesApplicationAudioSession = YES;
            
            // ========== 1. 获取并配置后置摄像头 ==========
            AVCaptureDevice *backCamera = [self getBestBackCamera];
            if (!backCamera) {
                [self addLog:@"❌ 找不到后置摄像头"];
                [self sendErrorWithCode:WfmCameraErrorCameraUnavailable 
                                    msg:@"找不到后置摄像头" 
                              errorType:kErrorTypeCameraUnavailable 
                               callback:self.currentCallback];
                return;
            }
            
            [self addLog:[NSString stringWithFormat:@"后置摄像头: %@", backCamera.localizedName]];
            
            // 配置后置摄像头
            NSError *configError = nil;
            if ([backCamera lockForConfiguration:&configError]) {
                // 设置帧率 30fps
                CMTime frameDuration = CMTimeMake(1, 30);
                backCamera.activeVideoMinFrameDuration = frameDuration;
                backCamera.activeVideoMaxFrameDuration = frameDuration;
                
                // 设置曝光和白平衡
                if ([backCamera isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                    backCamera.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
                }
                if ([backCamera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                    backCamera.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
                }
                [backCamera unlockForConfiguration];
                [self addLog:@"✅ 后置摄像头配置完成"];
            }
            
            // ========== 2. 获取并配置前置摄像头 ==========
            AVCaptureDevice *frontCamera = [self getBestFrontCamera];
            if (!frontCamera) {
                [self addLog:@"❌ 找不到前置摄像头"];
                [self sendErrorWithCode:WfmCameraErrorCameraUnavailable 
                                    msg:@"找不到前置摄像头" 
                              errorType:kErrorTypeCameraUnavailable 
                               callback:self.currentCallback];
                return;
            }
            
            [self addLog:[NSString stringWithFormat:@"前置摄像头: %@", frontCamera.localizedName]];
            
            if ([frontCamera lockForConfiguration:&configError]) {
                CMTime frameDuration = CMTimeMake(1, 30);
                frontCamera.activeVideoMinFrameDuration = frameDuration;
                frontCamera.activeVideoMaxFrameDuration = frameDuration;
                
                if ([frontCamera isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                    frontCamera.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
                }
                if ([frontCamera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                    frontCamera.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
                }
                [frontCamera unlockForConfiguration];
                [self addLog:@"✅ 前置摄像头配置完成"];
            }
            
            // ========== 3. 添加输入 ==========
            NSError *error = nil;
            self.backInput = [AVCaptureDeviceInput deviceInputWithDevice:backCamera error:&error];
            if (error || ![self.multiCamSession canAddInput:self.backInput]) {
                [self addLog:[NSString stringWithFormat:@"❌ 无法添加后置输入: %@", error.localizedDescription]];
                [self sendErrorWithCode:WfmCameraErrorSetupFailed 
                                    msg:@"后置摄像头添加失败" 
                              errorType:kErrorTypeSetupFailed 
                               callback:self.currentCallback];
                return;
            }
            [self.multiCamSession addInput:self.backInput];
            [self addLog:@"✅ 后置输入添加成功"];
            
            self.frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
            if (error || ![self.multiCamSession canAddInput:self.frontInput]) {
                [self addLog:[NSString stringWithFormat:@"❌ 无法添加前置输入: %@", error.localizedDescription]];
                [self sendErrorWithCode:WfmCameraErrorSetupFailed 
                                    msg:@"前置摄像头添加失败" 
                              errorType:kErrorTypeSetupFailed 
                               callback:self.currentCallback];
                return;
            }
            [self.multiCamSession addInput:self.frontInput];
            [self addLog:@"✅ 前置输入添加成功"];
            
            // ========== 4. 添加视频输出 ==========
            dispatch_queue_t outputQueue = dispatch_queue_create("com.wfm.camera.output", DISPATCH_QUEUE_SERIAL);
            
            // 后置视频输出
            self.backOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.backOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            self.backOutput.alwaysDiscardsLateVideoFrames = NO;  // 关键: 不丢弃延迟帧
            [self.backOutput setSampleBufferDelegate:self queue:outputQueue];
            
            if ([self.multiCamSession canAddOutput:self.backOutput]) {
                [self.multiCamSession addOutput:self.backOutput];
                [self addLog:@"✅ 后置输出添加成功"];
            }
            
            // 前置视频输出
            self.frontOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.frontOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            self.frontOutput.alwaysDiscardsLateVideoFrames = NO;  // 关键: 不丢弃延迟帧
            [self.frontOutput setSampleBufferDelegate:self queue:outputQueue];
            
            if ([self.multiCamSession canAddOutput:self.frontOutput]) {
                [self.multiCamSession addOutput:self.frontOutput];
                [self addLog:@"✅ 前置输出添加成功"];
            }
            
            // ========== 5. 建立连接并设置方向 ==========
            [self setupConnections];
            
            // ========== 6. 获取当前视图 ==========
            UIViewController *topVC = [self getTopViewController];
            if (!topVC) {
                [self addLog:@"❌ 无法获取当前视图"];
                [self sendErrorWithCode:WfmCameraErrorSetupFailed 
                                    msg:@"无法获取当前视图" 
                              errorType:kErrorTypeSetupFailed 
                               callback:self.currentCallback];
                return;
            }
            
            // ========== 7. 创建预览视图 ==========
            [self createPreviewViews:topVC];
            
            // ========== 8. 启动会话 ==========
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [self.multiCamSession startRunning];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.multiCamSession.isRunning) {
                        [self addLog:@"✅ 会话启动成功"];
                        // 启动画面检测定时器
                        [self startVideoOutputCheckTimer];
                    } else {
                        [self addLog:@"⚠️ 会话启动失败"];
                        [self sendErrorWithCode:WfmCameraErrorSetupFailed
                                            msg:@"摄像头会话启动失败"
                                      errorType:kErrorTypeSetupFailed
                                       callback:self.currentCallback];
                    }
                });
            });
            
        } @catch (NSException *exception) {
            [self addLog:[NSString stringWithFormat:@"❌ 设置双摄时崩溃: %@", exception.reason]];
            [self sendErrorWithCode:WfmCameraErrorSetupFailed 
                                msg:exception.reason 
                          errorType:kErrorTypeSetupFailed 
                           callback:self.currentCallback];
        }
    });
}

#pragma mark - 获取最佳摄像头
- (AVCaptureDevice *)getBestBackCamera API_AVAILABLE(ios(10.0)) {
    AVCaptureDevice *camera = nil;
    
    if (@available(iOS 13.0, *)) {
        camera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                    mediaType:AVMediaTypeVideo
                                                     position:AVCaptureDevicePositionBack];
    }
    
    if (!camera) {
        camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    return camera;
}

- (AVCaptureDevice *)getBestFrontCamera API_AVAILABLE(ios(10.0)) {
    AVCaptureDevice *camera = nil;
    
    if (@available(iOS 13.0, *)) {
        camera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                    mediaType:AVMediaTypeVideo
                                                     position:AVCaptureDevicePositionFront];
    }
    
    if (!camera) {
        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        for (AVCaptureDevice *device in devices) {
            if (device.position == AVCaptureDevicePositionFront) {
                camera = device;
                break;
            }
        }
    }
    
    return camera;
}

#pragma mark - 建立连接
- (void)setupConnections API_AVAILABLE(ios(13.0)) {
    // 后置摄像头连接
    if (self.backInput && self.backOutput) {
        AVCaptureConnection *backConnection = nil;
        for (AVCaptureConnection *connection in self.multiCamSession.connections) {
            if ([connection.inputPorts containsObject:self.backInput.ports.firstObject] &&
                connection.output == self.backOutput) {
                backConnection = connection;
                break;
            }
        }
        
        if (!backConnection && self.backInput.ports.count > 0) {
            backConnection = [AVCaptureConnection connectionWithInputPorts:self.backInput.ports 
                                                                    output:self.backOutput];
        }
        
        if (backConnection && [self.multiCamSession canAddConnection:backConnection]) {
            if ([backConnection isVideoOrientationSupported]) {
                backConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
                [self addLog:@"✅ 后置视频方向设置为竖屏"];
            }
            [self.multiCamSession addConnection:backConnection];
            [self addLog:@"✅ 后置连接已添加"];
        }
    }
    
    // 前置摄像头连接
    if (self.frontInput && self.frontOutput) {
        AVCaptureConnection *frontConnection = nil;
        for (AVCaptureConnection *connection in self.multiCamSession.connections) {
            if ([connection.inputPorts containsObject:self.frontInput.ports.firstObject] &&
                connection.output == self.frontOutput) {
                frontConnection = connection;
                break;
            }
        }
        
        if (!frontConnection && self.frontInput.ports.count > 0) {
            frontConnection = [AVCaptureConnection connectionWithInputPorts:self.frontInput.ports 
                                                                     output:self.frontOutput];
        }
        
        if (frontConnection && [self.multiCamSession canAddConnection:frontConnection]) {
            if ([frontConnection isVideoOrientationSupported]) {
                frontConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
                [self addLog:@"✅ 前置视频方向设置为竖屏"];
            }
            if (frontConnection.isVideoMirroringSupported) {
                frontConnection.videoMirrored = YES;
                [self addLog:@"✅ 前置摄像头镜像已开启"];
            }
            [self.multiCamSession addConnection:frontConnection];
            [self addLog:@"✅ 前置连接已添加"];
        }
    }
}

#pragma mark - 创建预览视图
- (void)createPreviewViews:(UIViewController *)topVC {
    CGFloat viewWidth = topVC.view.bounds.size.width;
    CGFloat viewHeight = topVC.view.bounds.size.height;
    
    // 计算视频比例
    CGSize backResolution = CGSizeMake(1920, 1080);
    if (self.backInput && self.backInput.device.activeFormat) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(self.backInput.device.activeFormat.formatDescription);
        backResolution = CGSizeMake(dims.width, dims.height);
    }
    [self addLog:[NSString stringWithFormat:@"原始分辨率: %.0fx%.0f", backResolution.width, backResolution.height]];
    
    CGFloat videoAspectRatio = backResolution.height / backResolution.width;
    [self addLog:[NSString stringWithFormat:@"视频比例: %.3f", videoAspectRatio]];
    
    // 后置预览视图（全屏）
    self.backPreviewView = [[UIView alloc] initWithFrame:topVC.view.bounds];
    self.backPreviewView.backgroundColor = [UIColor blackColor];
    [topVC.view addSubview:self.backPreviewView];
    
    // 计算适配后的尺寸
    CGFloat imageWidth, imageHeight;
    if (videoAspectRatio > viewHeight / viewWidth) {
        imageHeight = viewHeight;
        imageWidth = imageHeight / videoAspectRatio;
    } else {
        imageWidth = viewWidth;
        imageHeight = imageWidth * videoAspectRatio;
    }
    
    CGFloat imageX = (viewWidth - imageWidth) / 2;
    CGFloat imageY = (viewHeight - imageHeight) / 2;
    
    self.backImageView = [[UIImageView alloc] initWithFrame:CGRectMake(imageX, imageY, imageWidth, imageHeight)];
    self.backImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backImageView.backgroundColor = [UIColor clearColor];
    [self.backPreviewView addSubview:self.backImageView];
    [self addLog:@"✅ 后置预览视图已创建"];
    
    // 前置预览小窗
    CGFloat smallWidth = 120;
    CGFloat smallHeight = smallWidth * videoAspectRatio;
    CGFloat margin = 16;
    CGFloat topOffset = 100;
    
    self.frontPreviewView = [[UIView alloc] initWithFrame:CGRectMake(
        viewWidth - smallWidth - margin,
        topOffset,
        smallWidth,
        smallHeight
    )];
    self.frontPreviewView.backgroundColor = [UIColor blackColor];
    self.frontPreviewView.layer.cornerRadius = 8;
    self.frontPreviewView.layer.masksToBounds = YES;
    self.frontPreviewView.layer.borderWidth = 2;
    self.frontPreviewView.layer.borderColor = [UIColor whiteColor].CGColor;
    [topVC.view addSubview:self.frontPreviewView];
    
    self.frontImageView = [[UIImageView alloc] initWithFrame:self.frontPreviewView.bounds];
    self.frontImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.frontImageView.backgroundColor = [UIColor clearColor];
    [self.frontPreviewView addSubview:self.frontImageView];
    [self addLog:@"✅ 前置预览小窗已创建"];
    
    // 添加按钮
    self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.closeButton.frame = CGRectMake(20, 50, 44, 44);
    self.closeButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    self.closeButton.layer.cornerRadius = 22;
    [self.closeButton setTitle:@"←" forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightMedium];
    [self.closeButton addTarget:self action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [topVC.view addSubview:self.closeButton];
    
    self.captureButton = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat buttonSize = 70;
    self.captureButton.frame = CGRectMake(
        (viewWidth - buttonSize) / 2,
        viewHeight - buttonSize - 40,
        buttonSize,
        buttonSize
    );
    self.captureButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    self.captureButton.layer.cornerRadius = buttonSize / 2;
    self.captureButton.layer.borderWidth = 3;
    self.captureButton.layer.borderColor = [UIColor whiteColor].CGColor;
    [self.captureButton addTarget:self action:@selector(captureButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [topVC.view addSubview:self.captureButton];
}

- (void)captureButtonTapped {
    if (self.isTakingPhoto) {
        [self addLog:@"正在拍照中，请稍后..."];
        return;
    }
    
    [self addLog:@"📷 开始拍照"];
    self.isTakingPhoto = YES;
    
    self.waitingForBackPhoto = YES;
    self.waitingForFrontPhoto = YES;
    self.backImage = nil;
    self.frontImage = nil;
}

- (void)closeDualCameraAndCleanup {
    [self addLog:@"关闭双摄并释放资源"];
    [self stopVideoOutputCheckTimer];
    
    if (self.multiCamSession) {
        [self.multiCamSession stopRunning];
        
        if (self.backOutput) {
            [self.backOutput setSampleBufferDelegate:nil queue:NULL];
        }
        if (self.frontOutput) {
            [self.frontOutput setSampleBufferDelegate:nil queue:NULL];
        }
        
        [self.backPreviewView removeFromSuperview];
        [self.frontPreviewView removeFromSuperview];
        [self.closeButton removeFromSuperview];
        [self.captureButton removeFromSuperview];
        
        self.multiCamSession = nil;
        self.backInput = nil;
        self.frontInput = nil;
        self.backOutput = nil;
        self.frontOutput = nil;
        self.backImageView = nil;
        self.frontImageView = nil;
        self.backPreviewView = nil;
        self.frontPreviewView = nil;
        self.closeButton = nil;
        self.captureButton = nil;
        
        [self addLog:@"✅ 资源已释放"];
    }
}

- (void)closeButtonTapped {
    [self addLog:@"用户点击返回，取消拍照"];
    [self closeDualCameraAndCleanup];
    [self sendErrorWithCode:WfmCameraErrorUserCancel 
                        msg:@"用户取消拍照" 
                  errorType:kErrorTypeUserCancel 
                   callback:self.currentCallback];
}

- (void)closeDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    [self addLog:@"========== 关闭双摄 =========="];
    [self closeDualCameraAndCleanup];
    [self sendResult:YES message:@"双摄已关闭" callback:callback];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!sampleBuffer) return;
    
    // 记录收到视频帧
    if (output == self.backOutput && !self.hasReceivedBackFrame) {
        self.hasReceivedBackFrame = YES;
        [self addLog:@"✅ 后置摄像头首次收到画面帧"];
    } else if (output == self.frontOutput && !self.hasReceivedFrontFrame) {
        self.hasReceivedFrontFrame = YES;
        [self addLog:@"✅ 前置摄像头首次收到画面帧"];
    }
    
    UIImageView *targetImageView = nil;
    
    if (output == self.backOutput) {
        targetImageView = self.backImageView;
    } else if (output == self.frontOutput) {
        targetImageView = self.frontImageView;
    }
    
    if (!targetImageView) return;
    
    UIImage *image = [self imageFromSampleBuffer:sampleBuffer];
    if (image) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (targetImageView.superview) {
                targetImageView.image = image;
            }
            
            if (self.isTakingPhoto) {
                if (output == self.backOutput && self.waitingForBackPhoto) {
                    // 后置照片：直接加水印
                    UIImage *watermarkedImage = [self addWatermarkToImage:image];
                    self.backImage = watermarkedImage;
                    self.waitingForBackPhoto = NO;
                    [self addLog:@"✅ 后置照片已捕获"];
                } else if (output == self.frontOutput && self.waitingForFrontPhoto) {
                    // 前置照片：镜像后加水印
                    UIImage *mirroredImage = [self flipImageHorizontally:image];
                    UIImage *watermarkedImage = [self addWatermarkToImage:mirroredImage];
                    self.frontImage = watermarkedImage;
                    self.waitingForFrontPhoto = NO;
                    [self addLog:@"✅ 前置照片已捕获"];
                }
                
                if (!self.waitingForBackPhoto && !self.waitingForFrontPhoto) {
                    self.isTakingPhoto = NO;
                    [self saveBothPhotosToTemp];
                }
            }
        });
    }
}

- (void)saveBothPhotosToTemp {
    [self addLog:@"开始保存前后照片到临时路径..."];
    
    __block NSString *backPath = nil;
    __block NSString *frontPath = nil;
    
    dispatch_group_t group = dispatch_group_create();
    
    // 保存后置照片到临时路径
    if (self.backImage) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            backPath = [self saveImageToTempPath:self.backImage withPrefix:@"back"];
            [self addLog:[NSString stringWithFormat:@"后置照片已保存: %@", backPath]];
            dispatch_group_leave(group);
        });
    }
    
    // 保存前置照片到临时路径
    if (self.frontImage) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            frontPath = [self saveImageToTempPath:self.frontImage withPrefix:@"front"];
            [self addLog:[NSString stringWithFormat:@"前置照片已保存: %@", frontPath]];
            dispatch_group_leave(group);
        });
    }
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self addLog:@"照片保存完成，关闭双摄"];
        [self closeDualCameraAndCleanup];
        
        if (backPath || frontPath) {
            [self sendSuccessWithBackPath:backPath frontPath:frontPath callback:self.currentCallback];
        } else {
            [self sendErrorWithCode:WfmCameraErrorSaveFailed 
                                msg:@"照片保存失败" 
                          errorType:kErrorTypeSaveFailed 
                           callback:self.currentCallback];
        }
        
        self.isTakingPhoto = NO;
    });
}

- (UIImage *)imageFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return nil;
    
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    if (!self.colorSpace) {
        self.colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, self.colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    
    CGImageRelease(cgImage);
    CGContextRelease(context);
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    
    return image;
}

#pragma mark - 获取当前视图控制器

- (UIViewController *)getTopViewController {
    UIViewController *vc = nil;
    
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *windowScene in [UIApplication sharedApplication].connectedScenes) {
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        vc = window.rootViewController;
                        break;
                    }
                }
            }
        }
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        vc = [UIApplication sharedApplication].keyWindow.rootViewController;
        #pragma clang diagnostic pop
    }
    
    UIViewController *currentShowingVC = [self findCurrentShowingViewControllerFrom:vc];
    return currentShowingVC;
}

- (UIViewController *)findCurrentShowingViewControllerFrom:(UIViewController *)vc {
    UIViewController *currentShowingVC;
    if ([vc presentedViewController]) {
        UIViewController *nextRootVC = [vc presentedViewController];
        currentShowingVC = [self findCurrentShowingViewControllerFrom:nextRootVC];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *nextRootVC = [(UITabBarController *)vc selectedViewController];
        currentShowingVC = [self findCurrentShowingViewControllerFrom:nextRootVC];
    } else if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *nextRootVC = [(UINavigationController *)vc visibleViewController];
        currentShowingVC = [self findCurrentShowingViewControllerFrom:nextRootVC];
    } else {
        currentShowingVC = vc;
    }
    return currentShowingVC;
}

#pragma mark - 图像处理

- (UIImage *)rotateImage:(UIImage *)image byDegrees:(CGFloat)degrees {
    CGAffineTransform transform = CGAffineTransformMakeRotation(degrees * M_PI / 180.0);
    CGSize rotatedSize = CGSizeMake(image.size.height, image.size.width);
    
    UIGraphicsBeginImageContext(rotatedSize);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, rotatedSize.width / 2, rotatedSize.height / 2);
    CGContextRotateCTM(context, degrees * M_PI / 180.0);
    [image drawInRect:CGRectMake(-image.size.width / 2, -image.size.height / 2, image.size.width, image.size.height)];
    UIImage *rotatedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return rotatedImage;
}

- (UIImage *)flipImageHorizontally:(UIImage *)image {
    UIGraphicsBeginImageContext(image.size);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, image.size.width, 0);
    CGContextScaleCTM(context, -1.0, 1.0);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *flippedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return flippedImage;
}

#pragma mark - 水印

- (NSArray *)getWatermarkTexts {
    NSDate *now = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timeString = [formatter stringFromDate:now];
    
    NSString *location = self.watermarkLocation.length > 0 ? self.watermarkLocation : @"未知";
    NSString *lngLat = @"";
    if (self.watermarkLatitude.length > 0 && self.watermarkLongitude.length > 0) {
        lngLat = [NSString stringWithFormat:@"%@,%@", self.watermarkLatitude, self.watermarkLongitude];
    } else {
        lngLat = @"未知";
    }
    NSString *operatorName = self.watermarkOperator.length > 0 ? self.watermarkOperator : @"未知";
    
    return @[
        [NSString stringWithFormat:@"拍摄时间：%@", timeString],
        [NSString stringWithFormat:@"拍摄地点：%@", location],
        [NSString stringWithFormat:@"经纬度：%@", lngLat],
        [NSString stringWithFormat:@"操作人：%@", operatorName],
        @"智慧电梯维保平台"
    ];
}

- (NSArray *)getWatermarkColors {
    return @[
        [UIColor whiteColor],
        [UIColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0],
        [UIColor colorWithRed:0.0 green:1.0 blue:0.6 alpha:1.0],
        [UIColor colorWithRed:0.0 green:1.0 blue:1.0 alpha:1.0],
        [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]
    ];
}

- (UIImage *)addWatermarkToImage:(UIImage *)image {
    CGSize imageSize = image.size;
    
    CGFloat fontSize = 14.0;
    if (imageSize.width > 2000) fontSize = 18.0;
    else if (imageSize.width > 1000) fontSize = 16.0;
    else fontSize = 14.0;
    
    CGFloat padding = 10.0;
    CGFloat spacing = 4.0;
    CGFloat margin = 16.0;
    CGFloat cornerRadius = 6.0;
    
    NSArray *texts = [self getWatermarkTexts];
    NSArray *colors = [self getWatermarkColors];
    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium];
    
    CGFloat maxTextWidth = 0;
    CGFloat totalTextHeight = 0;
    NSMutableArray *textHeights = [NSMutableArray array];
    
    for (NSString *text in texts) {
        NSDictionary *attrs = @{NSFontAttributeName: font};
        CGRect rect = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:attrs
                                         context:nil];
        maxTextWidth = MAX(maxTextWidth, rect.size.width);
        totalTextHeight += rect.size.height;
        [textHeights addObject:@(rect.size.height)];
    }
    totalTextHeight += spacing * (texts.count - 1);
    
    CGFloat bgWidth = maxTextWidth + padding * 2;
    CGFloat bgHeight = totalTextHeight + padding * 2;
    CGFloat bgX = margin;
    CGFloat bgY = imageSize.height - margin - bgHeight;
    
    UIGraphicsBeginImageContextWithOptions(imageSize, NO, 1.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    [image drawInRect:CGRectMake(0, 0, imageSize.width, imageSize.height)];
    
    UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(bgX, bgY, bgWidth, bgHeight)
                                                       cornerRadius:cornerRadius];
    [[UIColor colorWithWhite:0 alpha:0.5] setFill];
    [bgPath fill];
    
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.5].CGColor);
    CGContextSetLineWidth(context, 1.0);
    UIBezierPath *borderPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(bgX + 0.5, bgY + 0.5, bgWidth - 1, bgHeight - 1)
                                                          cornerRadius:cornerRadius - 0.5];
    [borderPath stroke];
    
    CGFloat currentY = bgY + padding;
    for (NSInteger i = 0; i < texts.count; i++) {
        NSString *text = texts[i];
        UIColor *color = colors[i];
        CGFloat textHeight = [textHeights[i] floatValue];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color
        };
        
        CGFloat textX = bgX + padding;
        CGFloat textY = currentY + (textHeight - textHeight) / 2;
        [text drawAtPoint:CGPointMake(textX, textY) withAttributes:attrs];
        
        currentY += textHeight + spacing;
    }
    
    UIImage *watermarkedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return watermarkedImage;
}

#pragma mark - 摄像头格式配置

- (AVCaptureDeviceFormat *)bestFormatForDevice:(AVCaptureDevice *)device {
    if (!device) return nil;
    
    AVCaptureDeviceFormat *bestFormat = nil;
    int maxArea = 0;
    
    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        int area = dims.width * dims.height;
        float aspectRatio = (float)dims.width / (float)dims.height;
        BOOL isWideScreen = fabs(aspectRatio - 16.0/9.0) < 0.1;
        
        if (area > maxArea) {
            if (isWideScreen) {
                maxArea = area;
                bestFormat = format;
            } else if (!bestFormat) {
                maxArea = area;
                bestFormat = format;
            }
        }
    }
    
    return bestFormat;
}

- (BOOL)configureBestFormatForDevice:(AVCaptureDevice *)device {
    if (!device) return NO;
    
    AVCaptureDeviceFormat *bestFormat = [self bestFormatForDevice:device];
    if (!bestFormat) {
        [self addLog:@"⚠️ 未找到合适的格式"];
        return NO;
    }
    
    NSError *error = nil;
    if (![device lockForConfiguration:&error]) {
        [self addLog:[NSString stringWithFormat:@"⚠️ 无法锁定摄像头: %@", error.localizedDescription]];
        return NO;
    }
    
    device.activeFormat = bestFormat;
    CMTime frameDuration = CMTimeMake(1, 30);
    device.activeVideoMinFrameDuration = frameDuration;
    device.activeVideoMaxFrameDuration = frameDuration;
    
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
    [self addLog:[NSString stringWithFormat:@"✅ 设置摄像头格式: %dx%d", dims.width, dims.height]];
    
    [device unlockForConfiguration];
    return YES;
}

- (void)dealloc {
    [self stopVideoOutputCheckTimer];
    if (self.colorSpace) {
        CGColorSpaceRelease(self.colorSpace);
    }
}

@end
