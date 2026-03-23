#import "WfmCameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@interface WfmCameraPlugin ()

@property (nonatomic, strong) AVCaptureMultiCamSession *multiCamSession;
@property (nonatomic, strong) AVCaptureDeviceInput *backInput;
@property (nonatomic, strong) AVCaptureDeviceInput *frontInput;
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, strong) UIView *frontPreviewView;

@end

@implementation WfmCameraPlugin

// 暴露方法
UNI_EXPORT_METHOD(@selector(test:callback:))
UNI_EXPORT_METHOD(@selector(openDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(closeDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(log:callback:))

// 日志辅助方法
- (void)log:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *message = options[@"message"] ?: @"";
    NSLog(@"[WfmCameraPlugin] %@", message);
    if (callback) {
        callback(@{@"success": @YES, @"log": message}, NO);
    }
}

- (void)logMessage:(NSString *)message callback:(UniModuleKeepAliveCallback)callback {
    NSLog(@"[WfmCameraPlugin] %@", message);
    if (callback) {
        callback(@{@"success": @YES, @"log": message}, NO);
    }
}

- (void)logError:(NSString *)message error:(NSError *)error callback:(UniModuleKeepAliveCallback)callback {
    NSString *fullMsg = [NSString stringWithFormat:@"❌ %@: %@", message, error.localizedDescription];
    NSLog(@"[WfmCameraPlugin] %@", fullMsg);
    if (callback) {
        callback(@{@"success": @NO, @"log": fullMsg, @"error": error.localizedDescription}, NO);
    }
}

// test 方法
- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self logMessage:@"test 方法被调用" callback:callback];
    if (callback) {
        callback(@{@"success": @YES, @"msg": @"插件工作正常！"}, NO);
    }
}

// 打开双摄
- (void)openDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self logMessage:@"========== 打开双摄 ==========" callback:callback];
    
    @try {
        // 检查 iOS 版本
        if (@available(iOS 13.0, *)) {
            [self logMessage:@"iOS 13+ 检查通过" callback:callback];
        } else {
            [self logMessage:@"需要 iOS 13 或更高版本" callback:callback];
            if (callback) {
                callback(@{@"success": @NO, @"msg": @"需要 iOS 13 或更高版本"}, NO);
            }
            return;
        }
        
        // 检查权限
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        [self logMessage:[NSString stringWithFormat:@"相机权限状态: %ld", (long)status] callback:callback];
        
        if (status != AVAuthorizationStatusAuthorized) {
            if (status == AVAuthorizationStatusNotDetermined) {
                [self logMessage:@"请求相机权限..." callback:callback];
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) {
                            [self logMessage:@"权限已授权，开始打开双摄" callback:callback];
                            [self setupDualCamera:callback];
                        } else {
                            [self logMessage:@"用户拒绝相机权限" callback:callback];
                            if (callback) {
                                callback(@{@"success": @NO, @"msg": @"需要相机权限"}, NO);
                            }
                        }
                    });
                }];
            } else {
                [self logMessage:@"相机权限未授权" callback:callback];
                if (callback) {
                    callback(@{@"success": @NO, @"msg": @"请先在设置中开启相机权限"}, NO);
                }
            }
            return;
        }
        
        // 已有权限，直接打开
        [self setupDualCamera:callback];
    } @catch (NSException *exception) {
        [self logMessage:[NSString stringWithFormat:@"异常: %@", exception.reason] callback:callback];
        if (callback) {
            callback(@{@"success": @NO, @"msg": exception.reason}, NO);
        }
    }
}

// 关闭双摄
- (void)closeDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self logMessage:@"========== 关闭双摄 ==========" callback:callback];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.multiCamSession) {
            [self.multiCamSession stopRunning];
            [self logMessage:@"会话已停止" callback:callback];
            
            if (self.backPreviewView) {
                [self.backPreviewView removeFromSuperview];
                self.backPreviewView = nil;
                [self logMessage:@"后置预览视图已移除" callback:callback];
            }
            if (self.frontPreviewView) {
                [self.frontPreviewView removeFromSuperview];
                self.frontPreviewView = nil;
                [self logMessage:@"前置预览视图已移除" callback:callback];
            }
            
            self.multiCamSession = nil;
            self.backInput = nil;
            self.frontInput = nil;
            
            [self logMessage:@"双摄已关闭" callback:callback];
            if (callback) {
                callback(@{@"success": @YES, @"msg": @"双摄已关闭"}, NO);
            }
        } else {
            [self logMessage:@"双摄未开启" callback:callback];
            if (callback) {
                callback(@{@"success": @YES, @"msg": @"双摄未开启"}, NO);
            }
        }
    });
}

// 设置双摄预览
- (void)setupDualCamera:(UniModuleKeepAliveCallback)callback API_AVAILABLE(ios(13.0)) {
    [self logMessage:@"开始设置双摄..." callback:callback];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 1. 创建多摄会话
            [self logMessage:@"步骤1: 创建多摄会话..." callback:callback];
            self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
            self.multiCamSession.sessionPreset = AVCaptureSessionPresetPhoto;
            [self logMessage:@"步骤1: 多摄会话创建成功" callback:callback];
            
            // 2. 获取后置摄像头
            [self logMessage:@"步骤2: 获取后置摄像头..." callback:callback];
            AVCaptureDevice *backCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                              mediaType:AVMediaTypeVideo
                                                                               position:AVCaptureDevicePositionBack];
            if (!backCamera) {
                [self logMessage:@"步骤2: 找不到后置摄像头" callback:callback];
                if (callback) callback(@{@"success": @NO, @"msg": @"找不到后置摄像头"}, NO);
                return;
            }
            [self logMessage:[NSString stringWithFormat:@"步骤2: 找到后置摄像头: %@", backCamera.localizedName] callback:callback];
            
            // 3. 获取前置摄像头
            [self logMessage:@"步骤3: 获取前置摄像头..." callback:callback];
            AVCaptureDevice *frontCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                               mediaType:AVMediaTypeVideo
                                                                                position:AVCaptureDevicePositionFront];
            if (!frontCamera) {
                [self logMessage:@"步骤3: 找不到前置摄像头" callback:callback];
                if (callback) callback(@{@"success": @NO, @"msg": @"找不到前置摄像头"}, NO);
                return;
            }
            [self logMessage:[NSString stringWithFormat:@"步骤3: 找到前置摄像头: %@", frontCamera.localizedName] callback:callback];
            
            // 4. 添加后置输入
            [self logMessage:@"步骤4: 添加后置输入..." callback:callback];
            NSError *error = nil;
            self.backInput = [AVCaptureDeviceInput deviceInputWithDevice:backCamera error:&error];
            if (error) {
                [self logMessage:[NSString stringWithFormat:@"步骤4: 后置输入创建失败: %@", error.localizedDescription] callback:callback];
                if (callback) callback(@{@"success": @NO, @"msg": @"后置摄像头初始化失败"}, NO);
                return;
            }
            
            if ([self.multiCamSession canAddInput:self.backInput]) {
                [self.multiCamSession addInput:self.backInput];
                [self logMessage:@"步骤4: 后置输入添加成功" callback:callback];
            } else {
                [self logMessage:@"步骤4: 无法添加后置输入" callback:callback];
                if (callback) callback(@{@"success": @NO, @"msg": @"无法添加后置摄像头"}, NO);
                return;
            }
            
            // 5. 添加前置输入
            [self logMessage:@"步骤5: 添加前置输入..." callback:callback];
            self.frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
            if (error) {
                [self logMessage:[NSString stringWithFormat:@"步骤5: 前置输入创建失败: %@", error.localizedDescription] callback:callback];
                if (callback) callback(@{@"success": @NO, @"msg": @"前置摄像头初始化失败"}, NO);
                return;
            }
            
            if ([self.multiCamSession canAddInput:self.frontInput]) {
                [self.multiCamSession addInput:self.frontInput];
                [self logMessage:@"步骤5: 前置输入添加成功" callback:callback];
            } else {
                [self logMessage:@"步骤5: 无法添加前置输入" callback:callback];
                if (callback) callback(@{@"success": @NO, @"msg": @"无法添加前置摄像头"}, NO);
                return;
            }
            
            // 6. 启动会话
            [self logMessage:@"步骤6: 启动会话..." callback:callback];
            
            // 在后台线程启动会话，避免阻塞主线程
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [self.multiCamSession startRunning];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self logMessage:@"步骤6: 会话已启动" callback:callback];
                });
            });
            
            // 7. 获取当前视图
            [self logMessage:@"步骤7: 获取当前视图..." callback:callback];
            UIViewController *topVC = [self getTopViewController];
            if (!topVC) {
                [self logMessage:@"步骤7: 无法获取当前视图" callback:callback];
                if (callback) callback(@{@"success": @NO, @"msg": @"无法获取当前视图"}, NO);
                return;
            }
            [self logMessage:[NSString stringWithFormat:@"步骤7: 当前视图: %@", NSStringFromClass([topVC class])] callback:callback];
            
            // 8. 添加后置预览
            [self logMessage:@"步骤8: 添加后置预览..." callback:callback];
            self.backPreviewView = [[UIView alloc] initWithFrame:topVC.view.bounds];
            self.backPreviewView.backgroundColor = [UIColor blackColor];
            [topVC.view addSubview:self.backPreviewView];
            
            AVCaptureVideoPreviewLayer *backLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.multiCamSession];
            backLayer.frame = self.backPreviewView.bounds;
            backLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            
            // 设置后置摄像头连接
            if (backLayer.connection) {
                backLayer.connection.automaticallyAdjustsVideoMirroring = NO;
                backLayer.connection.videoMirrored = NO;
            }
            
            [self.backPreviewView.layer addSublayer:backLayer];
            [self logMessage:@"步骤8: 后置预览已添加" callback:callback];
            
            // 9. 添加前置小窗
            [self logMessage:@"步骤9: 添加前置小窗..." callback:callback];
            CGFloat smallWidth = 120;
            CGFloat smallHeight = 160;
            CGFloat margin = 16;
            CGFloat topOffset = 100;
            
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
            
            AVCaptureVideoPreviewLayer *frontLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.multiCamSession];
            frontLayer.frame = self.frontPreviewView.bounds;
            frontLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            
            // 设置前置摄像头连接并启用镜像
            if (frontLayer.connection) {
                frontLayer.connection.automaticallyAdjustsVideoMirroring = NO;
                if (frontLayer.connection.isVideoMirroringSupported) {
                    frontLayer.connection.videoMirrored = YES;
                    [self logMessage:@"步骤9: 前置镜像已设置" callback:callback];
                } else {
                    [self logMessage:@"步骤9: 设备不支持镜像" callback:callback];
                }
            }
            
            [self.frontPreviewView.layer addSublayer:frontLayer];
            [self logMessage:@"步骤9: 前置小窗已添加" callback:callback];
            
            [self logMessage:@"✅ 双摄预览已开启！" callback:callback];
            if (callback) {
                callback(@{@"success": @YES, @"msg": @"双摄预览已开启"}, NO);
            }
            
        } @catch (NSException *exception) {
            [self logMessage:[NSString stringWithFormat:@"设置双摄时崩溃: %@", exception.reason] callback:callback];
            if (callback) {
                callback(@{@"success": @NO, @"msg": exception.reason}, NO);
            }
        }
    });
}

// 获取当前视图控制器
- (UIViewController *)getTopViewController {
    UIViewController *topVC = nil;
    
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *windowScene in [UIApplication sharedApplication].connectedScenes) {
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        topVC = window.rootViewController;
                        break;
                    }
                }
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
#pragma clang diagnostic pop
    }
    
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = [(UINavigationController *)topVC visibleViewController];
    }
    return topVC;
}

@end
