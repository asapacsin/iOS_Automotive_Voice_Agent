//
//  e52e099f3_v1000_aee.h
//  ESREngine
//
//  Created by Jean on 2021/9/16.
//

#import <Foundation/Foundation.h>
#import "aee_eng_api.h"
#import "aee_eng_type.h"
NS_ASSUME_NONNULL_BEGIN

@interface ef7d69542_v1009_aee : NSObject

+ (instancetype)shareEngine;


/**
 * AEE runtime环境初始化、回调注册
 * @param runtimeContext    [in] 上下文
 * @param cfg               [in] 引擎配置参数对
 * @param cbs               [in] 注册回调接口
 * @return 接口错误码
 */
- (int)engineContext:(void*)runtimeContext config:(AEE_EngConfigPtr)cfg callback:(AEE_EngCallbacks)cbs;

- (int)engineUnContext;

/**
 * 获取引擎错误信息
 * @param  errNum   [in] 引擎服务层异常错误码
 * @param errMsg    [out] 错误码对应的错误描述信息
 * @return 接口错误码
 */
- (int)engineError:(int)errNum message:(char**)msg;

/**
 * 获取引擎版本信息
 * @param version [out] 引擎服务版本信息
 * @return 接口错误码
 */
- (int)engineVersion:(char**)version;

/**
 * 设置参数
 * @param  handle      [in] 实例句柄，用于关联上下文，为空时为全局参数设置
 * @param  params      [in] 会话参数对
 * @return 接口错误码
 */
- (int)engineSetParamWithHandle:(const void*)handle params:(AEE_EngParamPtr)params;

/**
 * 读取参数
 * @param  handle   [in]  实例句柄，用于关联上下文，为空时为全局参数设置
 * @param  key      [in]  参数key
 * @param  value    [out] value由引擎开辟和释放, 建议创建一个static value数组，避免内存频繁开辟释放
 * @param  len      [out] value实际长度
 * @param  type     [out] 参考AEE_VarType, 可为string, int, etc
 * @return 接口错误码
 */
- (int)engineGetParam:(const void *)hanlde key:(const char *)key value:(void **)value len:(int *)len type:(int *)type;


//***************************************************//
//*********************能力接口*********************//
//***************************************************//
/**
 * 引擎能力初始化
 * @param abilityId [in] 能力唯一标识ID
 * @param cfg       [in] 引擎能力配置对,外部用户不可见
 * @return 接口错误码
 */
- (int)abilityInit:(const char*)abilityId config:(AEE_AblConfigPtr)config;

/**
 * engine逆初始化
 * @param abilityId [in] 能力唯一标识ID
 * @return 接口错误码
 */
- (int)abilityFini:(const char*)abilityId;

/**
 * 资源加载
 * @param abilityId [in] 能力唯一标识ID
 * @param  resData  [in] 加载数据
 * @param  resInfo  [in] 数据标签，按位与值
 * @return 接口错误码
 */
- (int)abilityLoadRes:(const char*)abilityId resData:(AEE_ResDataPtr)resData resInfo:(AEE_ResInfo)resInfo;

/**
 * 资源卸载
 * @param abilityId [in] 能力唯一标识ID
 * @param  resId    [in] 资源标识，在LoadRes时由ResInfo参数带入
 * @return 接口错误码
 */
- (int)abilityUnloadRes:(const char*)abilityId resId:(size_t)resId;

/**
 * 个性化数据预处理
 * @param   abilityId   [in]  能力唯一标识
 * @param   inData      [in]  原始数据输入
 * @param   outData     [out] 结果数据输出,输出outData 在AEE_UnLoadCustomData释放
 * @return 错误码 0=成功，其他表示失败
 */
- (int)abilityPreprocess:(const char*)abilityId inData:(AEE_CustomData*)inData outData:(AEE_CustomData**)outData;

/**
 * 个性化数据加载接口
 * @param  abilityId   [in]  能力唯一标识
 * @param  data        [in] 由同步接口AEE_PreProcess获取的响应结果数据
 * @return 接口错误码
 */
- (int)abilityLoadData:(const char*)ability data:(AEE_CustomData*)data;

/**
 * 个性化数据释放接口
 * @param  abilityId   [in]  能力唯一标识
 * @param  key         [in]  个性化数据唯一标识
 * @param  index       [in]  个性化数据索引
 * @return 接口错误码
 */
- (int)abilityUnLoadData:(const char*)ability key:(const char*)key index:(int)index;

/**
 * 指定要使用的个性化数据集合，未调用，则默认使用所有AEE_LoadCustomData加载的数据
 * 用户可调用多次以指定使用不同key集合
 * @param  abilityId       [in]  能力唯一标识
 * @param  key             [in]  个性化数据唯一标识
 * @param  index           [in]  个性化数据索引数组
 * @param  count           [in]  个性化数据索引数组成员个数
 * @return 接口错误码
 */
- (int)abilitySpecifyDataSet:(const char*)ability key:(const char*)key index:(int [])index count:(int)count;

/// 以下接口为会话模式请求调用接口;
/// 1. 包含会话模式上下文相关接口：create/write/read/destroy;
/// 2. 包含同步模式/异步模式接口：createAsync/write/destroy;

/**
 * 创建异步计算资源
 * @param  abilityId   [in]  能力唯一标识
 * @param  params      [in]  会话参数对
 * @param  usrTag      [in]  sdk会话上下文句柄
 * @param  handle      [out] 引擎服务实例句柄,用于关联上下文
 * @return 接口错误码
 */
//- (int)abilityCreateAsync:(const char*)abilityId params:(AEE_EngParamPtr)params usrTag:(const void*)usrTag handle:(void**)handle;

/**
 * 创建同步计算资源
 * @param  abilityId   [in]  能力唯一标识
 * @param  params      [in]  会话参数对
 * @param  usrTag      [in]  sdk会话上下文句柄
 * @param  handle      [out] 引擎服务实例句柄,用于关联上下文
 * @return 接口错误码
 */
- (int)abilityCreate:(const char*)abilityId params:(AEE_EngParamPtr)params usrTag:(const void*)usrTag handle:(void**)handle;

/**
 * 开始计算
 * @param  handle      [in] 会话句柄,用于关联上下文;
 * @return 接口错误码
 */
- (int)abilityStart:(const void*)handle;

/**
 * 写入计算数据
 * @param  handle      [in] 实例句柄,用于关联上下文;
 * @param  reqData     [in] 写入数据实体
 * @return 接口错误码
 */
- (int)abilityWrite:(const void*)handle reqData:(AEE_EngDataPtr)reqData;

/*
    读取计算结果
    @param  handle      实例句柄,用于关联上下文;
    @param  respData    同步读取结果实体
    @return             接口错误码
    @note               respData内存由底层自行维护,在destroy阶段销毁
*/
- (int)abilityRead:(const void*)handle respData:(AEE_EngDataPtr*)respData;

/**
 * 停止计算
 * @param  handle      [in] 会话句柄,用于关联上下文;
 * @return 接口错误码
 */
- (int)abilityStop:(const void*)handle;

/**
 * 释放计算资源
 * @param  handle      [in] 会话句柄,用于关联上下文;
 * @return 接口错误码
 */
- (int)abilityDestroy:(const void*)handle;

/// 以下接口为非会话模式请求调用接口,对应引擎框架非流式协议消息;
/// 1. AEE_Exec()为同步阻塞接口,要求引擎服务阻塞带计算完成返回计算结果;
/// 2. AEE_ExecFree()为同步临时资源释放接口,用于释放AEE_Exec产生的临时结果数据;
/// 3. AEE_ExecAsync()为异步非阻塞接口,要求引擎服务即时返回,异步计算结果通过回调callback返回;

/**
 * 非流式计算接口
 * @param  abilityId  [in]  能力唯一标识
 * @param  params     [in]  会话参数对
 * @param  reqData    [in]  写入数据实体
 * @param  usrTag     [in]  sdk会话上下文句柄
 * @param  respData   [out] 返回结果实体,内存由底层引擎服务层申请维护,通过execFree()接口释放
 * @return 接口错误码
 * @note   同步操作接口, 需考虑上层并发调用可能
 */
-(int)abilityExec:(const char*)abilityId params:(AEE_EngParamPtr)params reqData:(AEE_EngDataPtr)reqData usrTag:(const void*)usrTag respData:(AEE_EngDataPtr*)respData;

/**
 * 同步接口响应数据缓存释放接口
 * @param  respData   [in] 由同步接口exec获取的响应结果数据
 * @return 接口错误码
 */
- (int)abilityExecFree:(AEE_EngDataPtr*)respData;

/**
 * 非流式异步计算接口
 * @param  abilityId  [in]  能力唯一标识
 * @param  params     [in] 配置参数
 * @param  reqData    [in] 写入数据实体
 * @param  usrTag     [in]  sdk会话上下文句柄
 * @param  timeout    [in] 异步超时时间,集成方实现该超时控制,单位ms;
 * @return 接口错误码
 * @note   异步操作接口, 需考虑上层并发调用可能
 */
- (int)abilityExecAsync:(const char*)abilityId params:(AEE_EngParamPtr)params reqData:(AEE_EngDataPtr)reqData usrTag:(const void*)usrTag timeout:(int)timeout;

@end

NS_ASSUME_NONNULL_END
