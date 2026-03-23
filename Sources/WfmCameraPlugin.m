#import "WfmCameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

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

@end

@implementation WfmCameraPlugin

// 暴露方法
UNI_EXPORT_METHOD(@selector(test:callback:))
UNI_EXPORT_METHOD(@selector(openDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(closeDualCamera:callback:))
UNI_EXPORT_METHOD(@selector(log:callback:))

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoQueue = dispatch_queue_create("com.wfm.camera.queue", DISPATCH_QUEUE_SERIAL);
        _logs = [NSMutableArray array];
    }
    return self;
}

// 添加日志到数组
- (void)addLog:(NSString *)message {
    if (!self.logs) {
        self.logs = [NSMutableArray array];
    }
    [self.logs addObject:message];
    NSLog(@"[WfmCameraPlugin] %@", message);
}

// 发送最终结果
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
}

// log 方法
- (void)log:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *message = options[@"message"] ?: @"";
    [self addLog:message];
    if (callback) {
        callback(@{@"success": @YES, @"log": message}, NO);
    }
}

// test 方法
- (void)test:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    [self addLog:@"========== test 方法开始 =========="];
    [self addLog:@"测试第一条日志"];
    [self addLog:@"测试第二条日志"];
    [self addLog:@"测试第三条日志"];
    [self addLog:@"========== test 方法结束 =========="];
    [self sendResult:YES message:@"插件工作正常！" callback:callback];
}

// 打开双摄
- (void)openDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    self.currentCallback = callback;
    
    [self addLog:@"========== 打开双摄 =========="];
    
    @try {
        // 检查 iOS 版本
        if (@available(iOS 13.0, *)) {
            [self addLog:@"✅ iOS 13+ 检查通过"];
        } else {
            [self addLog:@"❌ 需要 iOS 13 或更高版本"];
            [self sendResult:NO message:@"需要 iOS 13 或更高版本" callback:callback];
            return;
        }
        
        // 检查权限
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        [self addLog:[NSString stringWithFormat:@"相机权限状态: %ld", (long)status]];
        
        if (status != AVAuthorizationStatusAuthorized) {
            if (status == AVAuthorizationStatusNotDetermined) {
                [self addLog:@"请求相机权限..."];
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) {
                            [self addLog:@"✅ 权限已授权"];
                            [self setupDualCamera];
                        } else {
                            [self addLog:@"❌ 用户拒绝相机权限"];
                            [self sendResult:NO message:@"需要相机权限" callback:callback];
                        }
                    });
                }];
            } else {
                [self addLog:@"❌ 相机权限未授权"];
                [self sendResult:NO message:@"请先在设置中开启相机权限" callback:callback];
            }
            return;
        }
        
        [self addLog:@"✅ 相机权限已授权"];
        [self setupDualCamera];
        
    } @catch (NSException *exception) {
        [self addLog:[NSString stringWithFormat:@"❌ 异常: %@", exception.reason]];
        [self sendResult:NO message:exception.reason callback:callback];
    }
}

// 设置双摄预览
- (void)setupDualCamera API_AVAILABLE(ios(13.0)) {
    [self addLog:@"========== 开始设置双摄 =========="];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 步骤1: 创建多摄会话
            [self addLog:@"步骤1: 创建多摄会话..."];
            self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
            // 注意：AVCaptureMultiCamSession 不支持设置 sessionPreset，使用默认值
            [self addLog:@"步骤1: ✅ 多摄会话创建成功"];
            
            // 步骤2: 获取后置摄像头
            [self addLog:@"步骤2: 获取后置摄像头..."];
            AVCaptureDevice *backCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                              mediaType:AVMediaTypeVideo
                                                                               position:AVCaptureDevicePositionBack];
            if (!backCamera) {
                [self addLog:@"步骤2: ❌ 找不到后置摄像头"];
                [self sendResult:NO message:@"找不到后置摄像头" callback:self.currentCallback];
                return;
            }
            [self addLog:[NSString stringWithFormat:@"步骤2: ✅ 找到后置摄像头: %@", backCamera.localizedName]];
            
            // 步骤3: 获取前置摄像头
            [self addLog:@"步骤3: 获取前置摄像头..."];
            AVCaptureDevice *frontCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                               mediaType:AVMediaTypeVideo
                                                                                position:AVCaptureDevicePositionFront];
            if (!frontCamera) {
                [self addLog:@"步骤3: ❌ 找不到前置摄像头"];
                [self sendResult:NO message:@"找不到前置摄像头" callback:self.currentCallback];
                return;
            }
            [self addLog:[NSString stringWithFormat:@"步骤3: ✅ 找到前置摄像头: %@", frontCamera.localizedName]];
            
            // 步骤4: 添加后置输入
            [self addLog:@"步骤4: 添加后置输入..."];
            NSError *error = nil;
            self.backInput = [AVCaptureDeviceInput deviceInputWithDevice:backCamera error:&error];
            if (error) {
                [self addLog:[NSString stringWithFormat:@"步骤4: ❌ 后置输入创建失败: %@", error.localizedDescription]];
                [self sendResult:NO message:@"后置摄像头初始化失败" callback:self.currentCallback];
                return;
            }
            
            if ([self.multiCamSession canAddInput:self.backInput]) {
                [self.multiCamSession addInput:self.backInput];
                [self addLog:@"步骤4: ✅ 后置输入添加成功"];
            } else {
                [self addLog:@"步骤4: ❌ 无法添加后置输入"];
                [self sendResult:NO message:@"无法添加后置摄像头" callback:self.currentCallback];
                return;
            }
            
            // 步骤5: 添加前置输入
            [self addLog:@"步骤5: 添加前置输入..."];
            self.frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
            if (error) {
                [self addLog:[NSString stringWithFormat:@"步骤5: ❌ 前置输入创建失败: %@", error.localizedDescription]];
                [self sendResult:NO message:@"前置摄像头初始化失败" callback:self.currentCallback];
                return;
            }
            
            if ([self.multiCamSession canAddInput:self.frontInput]) {
                [self.multiCamSession addInput:self.frontInput];
                [self addLog:@"步骤5: ✅ 前置输入添加成功"];
            } else {
                [self addLog:@"步骤5: ❌ 无法添加前置输入"];
                [self sendResult:NO message:@"无法添加前置摄像头" callback:self.currentCallback];
                return;
            }
            
            // 步骤6: 添加后置视频输出
            [self addLog:@"步骤6: 添加后置视频输出..."];
            self.backOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.backOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            [self.backOutput setSampleBufferDelegate:self queue:self.videoQueue];
            
            if ([self.multiCamSession canAddOutput:self.backOutput]) {
                [self.multiCamSession addOutputWithNoConnections:self.backOutput];
                
                if (self.backInput.ports.count > 0) {
                    AVCaptureConnection *backConnection = [AVCaptureConnection connectionWithInputPorts:self.backInput.ports output:self.backOutput];
                    if (backConnection) {
                        if ([self.multiCamSession canAddConnection:backConnection]) {
                            [self.multiCamSession addConnection:backConnection];
                            [self addLog:@"步骤6: ✅ 后置视频输出添加成功"];
                        } else {
                            [self addLog:@"步骤6: ❌ 无法添加后置输出连接"];
                            [self sendResult:NO message:@"无法添加后置摄像头连接" callback:self.currentCallback];
                            return;
                        }
                    } else {
                        [self addLog:@"步骤6: ❌ 无法创建后置输出连接"];
                        [self sendResult:NO message:@"无法创建后置摄像头连接" callback:self.currentCallback];
                        return;
                    }
                } else {
                    [self addLog:@"步骤6: ❌ 后置输入端口为空"];
                    [self sendResult:NO message:@"后置摄像头端口为空" callback:self.currentCallback];
                    return;
                }
            } else {
                [self addLog:@"步骤6: ❌ 无法添加后置视频输出"];
                [self sendResult:NO message:@"无法添加后置视频输出" callback:self.currentCallback];
                return;
            }
            
            // 步骤7: 添加前置视频输出
            [self addLog:@"步骤7: 添加前置视频输出..."];
            self.frontOutput = [[AVCaptureVideoDataOutput alloc] init];
            self.frontOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            [self.frontOutput setSampleBufferDelegate:self queue:self.videoQueue];
            
            if ([self.multiCamSession canAddOutput:self.frontOutput]) {
                [self.multiCamSession addOutputWithNoConnections:self.frontOutput];
                
                if (self.frontInput.ports.count > 0) {
                    AVCaptureConnection *frontConnection = [AVCaptureConnection connectionWithInputPorts:self.frontInput.ports output:self.frontOutput];
                    if (frontConnection) {
                        if (frontConnection.isVideoMirroringSupported) {
                            frontConnection.videoMirrored = YES;
                        }
                        if ([self.multiCamSession canAddConnection:frontConnection]) {
                            [self.multiCamSession addConnection:frontConnection];
                            [self addLog:@"步骤7: ✅ 前置视频输出添加成功"];
                        } else {
                            [self addLog:@"步骤7: ❌ 无法添加前置输出连接"];
                            [self sendResult:NO message:@"无法添加前置摄像头连接" callback:self.currentCallback];
                            return;
                        }
                    } else {
                        [self addLog:@"步骤7: ❌ 无法创建前置输出连接"];
                        [self sendResult:NO message:@"无法创建前置摄像头连接" callback:self.currentCallback];
                        return;
                    }
                } else {
                    [self addLog:@"步骤7: ❌ 前置输入端口为空"];
                    [self sendResult:NO message:@"前置摄像头端口为空" callback:self.currentCallback];
                    return;
                }
            } else {
                [self addLog:@"步骤7: ❌ 无法添加前置视频输出"];
                [self sendResult:NO message:@"无法添加前置视频输出" callback:self.currentCallback];
                return;
            }
            
            // 步骤8: 获取当前视图（关键修复）
            [self addLog:@"步骤8: 获取当前视图..."];
            UIViewController *topVC = nil;
            
            // 方法1：通过 DCUniModule 的 uniInstance 获取（最可靠）
            if (self.uniInstance && self.uniInstance.viewController) {
                topVC = self.uniInstance.viewController;
                [self addLog:[NSString stringWithFormat:@"步骤8: ✅ 通过 uniInstance 获取到视图: %@", NSStringFromClass([topVC class])]];
            }
            
            // 方法2：如果方法1失败，尝试通过 UIApplication 获取
            if (!topVC) {
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
                    topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
                }
                
                while (topVC.presentedViewController) {
                    topVC = topVC.presentedViewController;
                }
                if ([topVC isKindOfClass:[UINavigationController class]]) {
                    topVC = [(UINavigationController *)topVC visibleViewController];
                }
                [self addLog:[NSString stringWithFormat:@"步骤8: ✅ 通过 window 获取到视图: %@", NSStringFromClass([topVC class])]];
            }
            
            if (!topVC) {
                [self addLog:@"步骤8: ❌ 无法获取当前视图"];
                [self sendResult:NO message:@"无法获取当前视图" callback:self.currentCallback];
                return;
            }
            
            // 步骤9: 创建后置预览视图
            [self addLog:@"步骤9: 创建后置预览视图..."];
            self.backPreviewView = [[UIView alloc] initWithFrame:topVC.view.bounds];
            self.backPreviewView.backgroundColor = [UIColor blackColor];
            [topVC.view addSubview:self.backPreviewView];
            
            self.backImageView = [[UIImageView alloc] initWithFrame:self.backPreviewView.bounds];
            self.backImageView.contentMode = UIViewContentModeScaleAspectFill;
            [self.backPreviewView addSubview:self.backImageView];
            [self addLog:@"步骤9: ✅ 后置预览视图已创建"];
            
            // 步骤10: 创建前置预览小窗
            [self addLog:@"步骤10: 创建前置预览小窗..."];
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
            
            self.frontImageView = [[UIImageView alloc] initWithFrame:self.frontPreviewView.bounds];
            self.frontImageView.contentMode = UIViewContentModeScaleAspectFill;
            [self.frontPreviewView addSubview:self.frontImageView];
            [self addLog:@"步骤10: ✅ 前置预览小窗已创建"];
            
            // 步骤11: 启动会话
            [self addLog:@"步骤11: 启动会话..."];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [self.multiCamSession startRunning];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self addLog:@"步骤11: ✅ 会话已启动"];
                    [self addLog:@"🎉 ========== 双摄预览已开启！ =========="];
                    [self sendResult:YES message:@"双摄预览已开启" callback:self.currentCallback];
                });
            });
            
        } @catch (NSException *exception) {
            [self addLog:[NSString stringWithFormat:@"❌ 设置双摄时崩溃: %@", exception.reason]];
            [self sendResult:NO message:exception.reason callback:self.currentCallback];
        }
    });
}

// 关闭双摄
- (void)closeDualCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self.logs removeAllObjects];
    [self addLog:@"========== 关闭双摄 =========="];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.multiCamSession) {
            [self.multiCamSession stopRunning];
            [self addLog:@"✅ 会话已停止"];
            
            if (self.backOutput) {
                [self.backOutput setSampleBufferDelegate:nil queue:NULL];
            }
            if (self.frontOutput) {
                [self.frontOutput setSampleBufferDelegate:nil queue:NULL];
            }
            
            if (self.backPreviewView) {
                [self.backPreviewView removeFromSuperview];
                self.backPreviewView = nil;
                [self addLog:@"后置预览视图已移除"];
            }
            if (self.frontPreviewView) {
                [self.frontPreviewView removeFromSuperview];
                self.frontPreviewView = nil;
                [self addLog:@"前置预览视图已移除"];
            }
            
            self.multiCamSession = nil;
            self.backInput = nil;
            self.frontInput = nil;
            self.backOutput = nil;
            self.frontOutput = nil;
            self.backImageView = nil;
            self.frontImageView = nil;
            
            [self addLog:@"✅ 双摄已关闭"];
        } else {
            [self addLog:@"⚠️ 双摄未开启"];
        }
        
        [self sendResult:YES message:@"双摄已关闭" callback:callback];
    });
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (!sampleBuffer) return;
    
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
        });
    }
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

- (void)dealloc {
    if (self.colorSpace) {
        CGColorSpaceRelease(self.colorSpace);
    }
}

@end
