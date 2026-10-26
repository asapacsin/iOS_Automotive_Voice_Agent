//
//  AiHelper.h
//  AIKIT
//
//  Created by pcfang on 20.3.22.
//

#import <Foundation/Foundation.h>
#import <AIKIT/AIKITError.h>
#import <AIKIT/AIKITDataModel.h>
#import <AIKIT/AiHandle.h>
#import <AIKIT/AiAudioDefine.h>

@class AiHelperMaker;
@class AIKITAudioBuilder;

#define AIKITDEPRECATED(msg) __attribute__((deprecated(msg)))

typedef NS_ENUM(NSInteger, AIKIT_EVENT_IOS) {
    AIKIT_EVENT_UNKNOWN  = 0,
    AIKIT_EVENT_START    = 1,
    AIKIT_EVENT_END      = 2,
    AIKIT_EVENT_TIMEOUT  = 3,
    AIKIT_EVENT_PROGRESS = 4
};

typedef enum _AIKITLogLvl {
    AIKITLogVerbose = 0,
    AIKITLogDebug   = 1,
    AIKITLogInfo    = 2,
    AIKITLogWarn    = 3,
    AIKITLogError   = 4,
    AIKITLogFatal   = 5,
    AIKITLogOff     = 100
} AIKITLogLvl;

@class AIKITInputData;
@class AIKITCustomData;
@class AIKITParameters;
@class AIKITUserContext;
@class AIKITCtxContent;

NS_ASSUME_NONNULL_BEGIN

/// 能力回调代理
@protocol AIKitCoreDelegate<NSObject>
@optional
- (void)aikitOnResult:(NSString*)ability outputData:(NSArray<AIKITDataModel*>*)data usrCtx:(AIKITUserContext*)context AIKITDEPRECATED("use aikitOnResult:handleId:outputData:usrCtx instead");

- (void)aikitOnEvent:(NSString*)ability event:(NSInteger)event eventData:(NSArray<AIKITDataModel*>*)data usrCtx:(AIKITUserContext*)context AIKITDEPRECATED("use -aikitOnEvent:handleId:event:eventData:usrCtx instead");

- (void)aikitOnError:(NSString*)ability error:(AIKITError*)error usrCtx:(AIKITUserContext*)context AIKITDEPRECATED("use aikitOnError:handleId:error:usrCtx instead");


/// 能力结果回调
/// - Parameters:
///   - ability: 能力id
///   - handleId: 会话句柄
///   - data: 能力输出数据
///   - context: 用户自定义标识
- (void)aikitOnResult:(NSString *)ability
             handleId:(NSInteger)handleId
           outputData:(NSArray<AIKITDataModel *> *)data
               usrCtx:(AIKITCtxContent *)context;

/// 能力进度回调
/// - Parameters:
///   - ability: 能力id
///   - handleId: 会话句柄
///   - event: 进度事件 ( 0 : UnKnown, 1 : Start, 2 : End, 3 : Timeout, 4 : Progress)
///   - data: 进度数据
///   - context: 用户标识
- (void)aikitOnEvent:(NSString *)ability
            handleId:(NSInteger)handleId
               event:(NSInteger)event
           eventData:(NSArray<AIKITDataModel *> *)data
              usrCtx:(AIKITCtxContent *)context;

/// 能力错误回调
/// - Parameters:
///   - ability: 能力id
///   - handleId: 会话句柄
///   - error: 错误信息
///   - context: 用户表示
- (void)aikitOnError:(NSString*)ability
            handleId:(NSInteger)handleId
               error:(AIKITError*)error
              usrCtx:(AIKITCtxContent*)context;
@end



@interface AiHelper : NSObject

- (instancetype)init NS_UNAVAILABLE;

+ (instancetype)shareInstance;

@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) NSMapTable* multiDelegates;

#pragma mark - SDK
///  SDK初始化
/// - Parameter block: 参数回调
+ (int)initSDK:(void(^)(AiHelperMaker *maker))block;

/// SDK逆初始化
+ (int)unInit;

#pragma mark - 引擎
/// 初始化能力引擎
/// - Parameters:
///   - ability: 能力id
///   - param: 引擎参数
+ (int)engineInit:(NSString *)ability param:(nullable AIKITParameters *)param;

/// 引擎逆初始化(多能力共用引擎句柄，先释放引擎在调用)
/// - Parameter ability: 能力id
+ (int) engineUnInit:(NSString *)ability;

/// 初始化能力引擎
/// - Parameters:
///   - ability: 能力id
///   - param: 引擎参数
+ (int)initEngine:(NSString*)ability param:(nullable AIKITParameters*)param AIKITDEPRECATED("use engineInit:param: instead");



#pragma mark - 非流式能力调用
/// 非流式调用（异步）
/// - Parameters:
///   - ability: 能力id
///   - param: 能力参数
///   - data: 输入数据
///   - content: 用户自定义
+ (int)oneShot:(NSString*)ability param:(AIKITParameters*)param data:(AIKITInputData*)data ctxContent:(nullable AIKITCtxContent*)content;


/// 异步非流式调用
/// - Parameters:
///   - ability: 能力id
///   - param: 能力参数
///   - data: 输入数据
///   - content: 用户自定义
+ (int)oneShotAsync:(NSString *)ability param:(AIKITParameters *)param data:(AIKITInputData *)data ctxContent:(nullable AIKITCtxContent *)content;

/// 同步流式
/// - Parameters:
///   - ability: 能力id
///   - param: 能力参数
///   - data: 能力数据
+ (NSArray <AIKITDataModel *> *) oneShotSync:(NSString *)ability param:(AIKITParameters *)param data:(AIKITInputData *)data;

#pragma mark - 流式能力调用
///  开启流式会话，返回会话句柄
/// - Parameters:
///   - ability: 能力id
///   - param: 能力参数
///   - content: 用户自定义
+ (AiHandle*)start:(NSString*)ability param:(nullable AIKITParameters*)param ctxContent:(nullable AIKITCtxContent*)content;

/// 流式写入数据
/// - Parameters:
///   - data: 输入数据
///   - handle: 会话句柄
+ (int)write:(nullable AIKITInputData*)data handle:(nonnull AiHandle*)handle;

/// 同步流式读取返回数据（异步流式能力无需调用）
/// - Parameter handle: 会话句柄
+ (int)read:(nonnull AiHandle*)handle;

/// 结束流式会话
/// - Parameter handle: 用户句柄
+ (int)end:(nonnull AiHandle*)handle;

#pragma mark - 能力相关

/// 获取能力授权剩余秒数
/// 能力输入参数为空时，默认返回最接近授权过期的能力剩余秒数
/// 注意：注意需在AEE_Init调用成功后，方可调用
/// 返回调用结果，0 = 成功， 其他值表示调用失败
/// - Parameters:
///   - abilityId: 能力id
///   - leftTime: 返回的能力授权剩余秒数，0 表示永久授权， 负值表示已过期的秒数
///   - endTime: 结束时间
+ (int)getAbility:(nonnull NSString *)abilityId authLeftTime:(int64_t *)leftTime endTime:(int64_t *)endTime;

/// 释放能力
/// - Parameter abilityId: 能力id
+ (int)freeAbility:(nonnull NSString *)abilityId;

#pragma mark - 个性化资源操作

/// 个性化资源加载
/// - Parameters:
///   - ability: 能力id
///   - data: 个性化数据
+ (int)loadData:(NSString*)ability data:(AIKITCustomData*)data;

/// 个性化资源预处理
/// - Parameters:
///   - ability: 能力id
///   - data: 个性化数据
+ (int)preProcess:(NSString*)ability data:(AIKITCustomData*)data;
/// 个性化资源自定生效
/// - Parameters:
///   - ability: 能力id
///   - key: 个性化key
///   - indexs: 指定个性化位置
///   - count:个性化数量
+ (int)specifyDataSet:(NSString*)ability key:(NSString*)key indexs:(nonnull int[])indexs count:(int)count;
/// 卸载指定位置的个性化资源
/// - Parameters:
///   - ability: 能力id
///   - key: 个性化key
///   - index: 指定位置
+ (int)unloadData:(NSString *)ability key:(NSString *)key index:(int)index;


#pragma mark - 日志设置

/// 日志设置
/// - Parameters:
///   - level: 日志等级
///   - mode: 日志输出方式
///   - path: 日志文件保存位置
+ (int)setLogInfo:(AIKITLogLvl)level mode:(NSInteger)mode path:(NSString*)path;


#pragma mark - 配置设置
/// 设置相关配置（兼容历史接口）
/// - Parameters:
///   - key: 配置key
///   - value: 配置
+ (int)setConfig:(nonnull NSString *)key value:(nonnull NSString *)value;

/// 设置相关配置（兼容历史接口）
/// - Parameters:
///   - key: 配置key
///   - value: 配置
+ (int)setConfig:(NSString *)key anyValue:(nonnull void *)value;


#pragma mark - 能力回调

/// 注册全局能力回调
/// - Parameter callback: 回调代理
+ (int)registerAppCallback:(id<AIKitCoreDelegate>)callback;

/// 注册能力级别回调
/// - Parameters:
///   - abilityId: 能力id
///   - callback: 回调代理
+ (int)registerAbilityCallback:(NSString*)abilityId callback:(id<AIKitCoreDelegate>)callback;

#pragma mark - widget (deprecated)
#pragma mark - Audio recorder

/// 开始录音
/// @param builder 构造器
+ (void)record:(nonnull AIKITAudioBuilder *)builder;

/// 是否正在录音
+ (BOOL)isRecording;

#pragma mark - Audio Codec

/// 音频编解码
/// @param inPath 音频输入路径
/// @param outPath 音频输出路径
/// @param audioType 输入/输出音频格式(encode为输出音频格式，decode为输入音频格式)
/// @param codecType 编码/解码
+ (int)codeC:(NSString *)inPath outPath:(NSString *)outPath audioType:(AudioType)audioType codecType:(AudioCodecType)codecType;

/// 音频编解码
/// @param inPath 音频输入路径
/// @param outPath 音频输出路径
/// @param audioType 输入/输出音频格式(encode为输出音频格式，decode为输入音频格式)
/// @param codecType 编码/解码
/// @param sampleRate  输出音频采样率
+ (int)codeC:(NSString *)inPath outPath:(NSString *)outPath audioType:(AudioType)audioType codecType:(AudioCodecType)codecType
  sampleRate:(uint32_t)sampleRate;

#pragma mark - Audio Player

/// 开始播放
/// @param builder 播放器参数构造
+ (int)startPlay:(AIKITAudioBuilder *)builder;

/// 暂停播放
+ (int)pausePlay;

/// 继续播放
+ (int)resumePlay;

/// 停止播放
+ (int)stopPlay;

+ (BOOL)isPlaying;

+ (BOOL)isPaused;

/// 写入音频数据
/// @param data 音频数据
+ (void)writeAudioData:(NSData *)data;

/// 写入音频完毕
+ (void)endAudioWrite;

@end

NS_ASSUME_NONNULL_END
