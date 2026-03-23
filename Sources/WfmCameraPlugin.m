#import "WfmCameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@interface WfmCameraPlugin () <AVCaptureVideoDataOutputSampleBufferDelegate>

// 双摄会话
@property (nonatomic, strong) AVCaptureMultiCamSession *multiCamSession;
@property (nonatomic, strong) AVCaptureDeviceInput *backInput;
@property (nonatomic, strong) AVCaptureDeviceInput *frontInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *backOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *frontOutput;

// 预览视图
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, strong) UIView *frontPreviewView;

@end

@implementation WfmCameraPlugin

// 保留 test 方法用于测试
UNI_EXPORT_METHOD(@selector(test:callback:))

// 双摄相关方法
UNI_EXPORT_METHOD(@selector(openDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(closeDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(checkCameraPermission:callback:))

// 日志辅助方法
- (void)log:(NSString *)message {
    // 使用 NSLog 也保留，但主要用 DCUniModule 的方法
    NSLog(@"[WfmCameraPlugin] %@", message);
    // 通过回调发送日志到前端（可选）
    [self sendLogToJS:message];
}

- (void)sendLogToJS:(NSString *)message {
    // 通过 uni 实例发送事件到前端
    if (self.uni) {
        [self.uni callJSMethod:@"__onPluginLog" args:@[message]];
    }
}

#pragma mark - test 方法（保留用于测试）
- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self log:@"test 方法被调用"];
    [self log:[NSString stringWithFormat:@"参数: %@", options]];
    
    if (callback) {
        callback(@{
            @"success": @YES,
            @"msg": @"插件工作正常！",
            @"params": options ?: @{}
        }, NO);
    }
}

#pragma mark - 权限检查
- (void)checkCameraPermission:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self log:@"========== 检查相机权限 =========="];
    
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    [self log:[NSString stringWithFormat:@"当前权限状态: %ld", (long)status]];
    
    if (status == AVAuthorizationStatusNotDetermined) {
        [self log:@"权限未确定，请求权限..."];
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            [self log:[NSString stringWithFormat:@"权限请求结果: %@", granted ? @"已授权" : @"已拒绝"]];
            if (callback) {
                callback(@{
                    @"success": @(granted),
                    @"status": granted ? @"authorized" : @"denied"
                }, NO);
            }
        }];
    } else {
        BOOL granted = (status == AVAuthorizationStatusAuthorized);
        NSString *statusStr = @"unknown";
        if (status == AVAuthorizationStatusAuthorized) {
            statusStr = @"authorized";
        } else if (status == AVAuthorizationStatusDenied) {
            statusStr = @"denied";
        } else if (status == AVAuthorizationStatusRestricted) {
            statusStr = @"restricted";
        }
        [self log:[NSString stringWithFormat:@"权限已确定: %@", statusStr]];
        
        if (callback) {
            callback(@{
                @"success": @(granted),
                @"status": statusStr
            }, NO);
        }
    }
}

#pragma mark - 打开双摄
- (void)openDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self log:@"========== 打开双摄 =========="];
    [self log:[NSString stringWithFormat:@"参数: %@", options]];
    
    // 检查 iOS 版本
    if (@available(iOS 13.0, *)) {
        [self log:@"iOS 版本检查通过 (iOS 13+)"];
    } else {
        NSString *errorMsg = @"需要 iOS 13 或更高版本";
        [self log:errorMsg];
        if (callback) {
            callback(@{@"success": @NO, @"msg": errorMsg}, NO);
        }
        return;
    }
    
    // 检查权限
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    [self log:[NSString stringWithFormat:@"权限状态: %ld", (long)status]];
    
    if (status != AVAuthorizationStatusAuthorized) {
        NSString *errorMsg = @"请先授予相机权限";
        [self log:errorMsg];
        if (callback) {
            callback(@{@"success": @NO, @"msg": errorMsg}, NO);
        }
        return;
    }
    
    // 在主线程设置 UI
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        BOOL success = [self setupDualCameraWithError:&error];
        
        if (success && self.multiCamSession && self.multiCamSession.isRunning) {
            [self log:@"✅ 双摄开启成功"];
            if (callback) {
                callback(@{@"success": @YES, @"msg": @"双摄已开启"}, NO);
            }
        } else {
            NSString *errorMsg = error ? error.localizedDescription : @"双摄开启失败，设备可能不支持";
            [self log:errorMsg];
            if (callback) {
                callback(@{@"success": @NO, @"msg": errorMsg}, NO);
            }
        }
    });
}

#pragma mark - 关闭双摄
- (void)closeDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self log:@"========== 关闭双摄 =========="];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.multiCamSession) {
            [self log:@"停止会话..."];
            [self.multiCamSession stopRunning];
            
            if (self.backPreviewView) {
                [self log:@"移除后置预览视图"];
                [self.backPreviewView removeFromSuperview];
                self.backPreviewView = nil;
            }
            if (self.frontPreviewView) {
                [self log:@"移除前置预览视图"];
                [self.frontPreviewView removeFromSuperview];
                self.frontPreviewView = nil;
            }
            
            self.multiCamSession = nil;
            self.backInput = nil;
            self.frontInput = nil;
            self.backOutput = nil;
            self.frontOutput = nil;
            
            [self log:@"✅ 双摄已关闭"];
        } else {
            [self log:@"⚠️ 双摄未开启，无需关闭"];
        }
        
        if (callback) {
            callback(@{@"success": @YES, @"msg": @"双摄已关闭"}, NO);
        }
    });
}

#pragma mark - 设置双摄
- (BOOL)setupDualCameraWithError:(NSError **)error API_AVAILABLE(ios(13.0)) {
    [self log:@"开始设置双摄..."];
    
    // 创建多摄会话
    self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
    self.multiCamSession.sessionPreset = AVCaptureSessionPresetPhoto;
    [self log:@"多摄会话创建成功"];
    
    // 获取摄像头设备
    AVCaptureDevice *backCamera = nil;
    AVCaptureDevice *frontCamera = nil;
    
    // 查找后置摄像头
    backCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                     mediaType:AVMediaTypeVideo
                                                      position:AVCaptureDevicePositionBack];
    if (backCamera) {
        [self log:[NSString stringWithFormat:@"找到后置摄像头: %@", backCamera.localizedName]];
    } else {
        [self log:@"❌ 找不到后置摄像头"];
        if (error) *error = [NSError errorWithDomain:@"WfmCameraPlugin" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"找不到后置摄像头"}];
        return NO;
    }
    
    // 查找前置摄像头
    frontCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                      mediaType:AVMediaTypeVideo
                                                       position:AVCaptureDevicePositionFront];
    if (frontCamera) {
        [self log:[NSString stringWithFormat:@"找到前置摄像头: %@", frontCamera.localizedName]];
    } else {
        [self log:@"❌ 找不到前置摄像头"];
        if (error) *error = [NSError errorWithDomain:@"WfmCameraPlugin" code:1002 userInfo:@{NSLocalizedDescriptionKey: @"找不到前置摄像头"}];
        return NO;
    }
    
    // 添加后置摄像头输入
    NSError *addError = nil;
    self.backInput = [AVCaptureDeviceInput deviceInputWithDevice:backCamera error:&addError];
    if (addError) {
        [self log:[NSString stringWithFormat:@"后置摄像头输入创建失败: %@", addError.localizedDescription]];
        if (error) *error = addError;
        return NO;
    }
    
    if ([self.multiCamSession canAddInput:self.backInput]) {
        [self.multiCamSession addInput:self.backInput];
        [self log:@"后置摄像头输入添加成功"];
    } else {
        [self log:@"❌ 无法添加后置摄像头输入"];
        if (error) *error = [NSError errorWithDomain:@"WfmCameraPlugin" code:1003 userInfo:@{NSLocalizedDescriptionKey: @"无法添加后置摄像头输入"}];
        return NO;
    }
    
    // 添加前置摄像头输入
    self.frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&addError];
    if (addError) {
        [self log:[NSString stringWithFormat:@"前置摄像头输入创建失败: %@", addError.localizedDescription]];
        if (error) *error = addError;
        return NO;
    }
    
    if ([self.multiCamSession canAddInput:self.frontInput]) {
        [self.multiCamSession addInput:self.frontInput];
        [self log:@"前置摄像头输入添加成功"];
    } else {
        [self log:@"❌ 无法添加前置摄像头输入"];
        if (error) *error = [NSError errorWithDomain:@"WfmCameraPlugin" code:1004 userInfo:@{NSLocalizedDescriptionKey: @"无法添加前置摄像头输入"}];
        return NO;
    }
    
    // 设置视频输出
    self.backOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.frontOutput = [[AVCaptureVideoDataOutput alloc] init];
    
    dispatch_queue_t queue = dispatch_queue_create("camera.queue", DISPATCH_QUEUE_SERIAL);
    [self.backOutput setSampleBufferDelegate:self queue:queue];
    [self.frontOutput setSampleBufferDelegate:self queue:queue];
    
    if ([self.multiCamSession canAddOutput:self.backOutput]) {
        [self.multiCamSession addOutput:self.backOutput];
        [self log:@"后置输出添加成功"];
    }
    if ([self.multiCamSession canAddOutput:self.frontOutput]) {
        [self.multiCamSession addOutput:self.frontOutput];
        [self log:@"前置输出添加成功"];
    }
    
    // 启动会话
    [self.multiCamSession startRunning];
    [self log:@"会话已启动"];
    
    // 获取当前显示的视图控制器
    UIViewController *topVC = [self getTopViewController];
    if (!topVC) {
        [self log:@"❌ 无法获取当前视图控制器"];
        if (error) *error = [NSError errorWithDomain:@"WfmCameraPlugin" code:1005 userInfo:@{NSLocalizedDescriptionKey: @"无法获取当前视图控制器"}];
        return NO;
    }
    [self log:[NSString stringWithFormat:@"获取到视图控制器: %@", NSStringFromClass([topVC class])]];
    
    // 后置摄像头全屏预览
    self.backPreviewView = [[UIView alloc] initWithFrame:topVC.view.bounds];
    self.backPreviewView.backgroundColor = [UIColor blackColor];
    [topVC.view addSubview:self.backPreviewView];
    [self log:@"后置预览视图已添加"];
    
    // 前置摄像头小窗（右上角）
    CGFloat smallWidth = 120;
    CGFloat smallHeight = 160;
    CGFloat margin = 16;
    CGFloat topOffset = 88; // 状态栏 + 导航栏高度
    
    self.frontPreviewView = [[UIView alloc] initWithFrame:CGRectMake(
        topVC.view.bounds.size.width - smallWidth - margin,
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
    [self log:@"前置预览小窗已添加"];
    
    // 添加预览图层
    AVCaptureVideoPreviewLayer *backPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.multiCamSession];
    backPreviewLayer.frame = self.backPreviewView.bounds;
    backPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.backPreviewView.layer addSublayer:backPreviewLayer];
    [self log:@"后置预览图层已添加"];
    
    AVCaptureVideoPreviewLayer *frontPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.multiCamSession];
    frontPreviewLayer.frame = self.frontPreviewView.bounds;
    frontPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.frontPreviewView.layer addSublayer:frontPreviewLayer];
    [self log:@"前置预览图层已添加"];
    
    // 设置前置摄像头镜像
    for (AVCaptureConnection *connection in frontPreviewLayer.connections) {
        for (AVCaptureInputPort *port in connection.inputPorts) {
            if ([port.mediaType isEqualToString:AVMediaTypeVideo] &&
                port.sourceDeviceInput.device.position == AVCaptureDevicePositionFront) {
                connection.videoMirrored = YES;
                [self log:@"前置摄像头镜像已设置"];
                break;
            }
        }
    }
    
    [self log:@"✅ 双摄设置完成"];
    return YES;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 视频帧处理（拍照功能后续添加）
}

#pragma mark - 获取当前显示的 ViewController
- (UIViewController *)getTopViewController {
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = [(UINavigationController *)topVC visibleViewController];
    }
    return topVC;
}

@end
