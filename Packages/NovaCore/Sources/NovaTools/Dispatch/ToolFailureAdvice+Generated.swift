// swiftlint:disable line_length
// Generated from the Android tables byte for byte (F-09); long literals stay on one line.
// GENERATED from `A/ToolFailureAdvice.kt` (evidence batch 1, commit 9c53929). Do not edit by hand.
import NovaKit

extension ToolFailureAdvice {
    static let generatedTable: [ToolErrorCode: String] = [
        .noMatch: "屏幕上的候选里没有这个名字。请如实说没有这个选项，并请用户说第几个。",
        .ambiguous: "有多个候选都符合这个名字。请如实说有多个，并请用户说第几个。",
        .outOfRange: "屏幕上没有这一项。请如实说没有这一项，并说明一共有几个。",
        .noOptionsOnScreen: "现在屏幕上没有候选列表。请如实说明，不要假装已经选择。",
        .optionsNotReady: "候选还在计算中。请让用户稍等，不要假装已经选择。",
        .optionsStale: "这个列表已经显示了一段时间（或刚从休眠中醒来），为了不选错，这次没有选择。请用一句话按 options_on_screen 简要重新说一遍有哪几项，再请用户说要第几个。不要说已经选好了。",
        .confirmCandidate: "没有完全同名的选项，但第 candidate_position 项「candidate_name」读音相近，没有选择任何一项。请只用一句话问用户是不是这一项（说出序号和名称），等用户确认；不要说已经选好了。",
        .distanceUnknown: "这些候选没有距离信息，无法判断最近的。请用户说第几个。",
        .preferenceNotForDestinations: "这个偏好只能用于路线，不能用于地点。请用户说第几个。",
        .preferenceNotForRoutes: "这个偏好只能用于地点，不能用于路线。请用户说第几条。",
        .noOptions: "现在没有可选的内容。请如实说明。",
        .ambiguousReferent: "用户这句话没有说明要调的是哪一项（options 里是可能的几项），之前的记录也无法确定，所以没有执行。请只用一句话反问用户是 options 里的哪一项（例如「是座椅还是温度？」），不要再调用任何工具，也不要说已经调好了。",
        .noRecentMosquito: "最近没有因为蚊子开过车窗，所以没有执行这个场景，车窗没有动。如果用户是想关窗，请用 control_window action=close 正常关窗；不要说已经关好了。",
        .duplicateInTurn: "这个操作在本轮已经执行过一次，没有重复执行。请根据上一次的结果回答，不要说又调了一次。",
        .noTelephony: "这辆车上现在没有可用的通话功能（没有 SIM 卡），所以打不了电话。请用一句话如实告诉用户，不要谎称已经拨号。",
        .callNotConfirmed: "用户还没有确认要给这个人打电话，所以没有拨号。请先用一句话问清楚是否要打给谁，得到答复后再调用一次。",
        .confirmationStale: "用户的确认已经是很久以前的了，不能当作现在的同意，所以没有拨号。请重新问一次是否要打电话。",
        .contactNotFound: "通讯录里没有找到这个人，没有拨号。请用一句话如实说没找到，请用户说完整的名字，不要猜一个人。",
        .contactsPermissionDenied: "没有通讯录权限，所以没有查找，也没有拨号。请用一句话如实告诉用户需要通讯录权限才能打电话，不要说没找到这个人。",
        .callFailed: "拨号没有成功，没有接通。请用一句话如实告诉用户没打出去，不要谎称已经接通。",
        .nearbyQuestionWhileNavigating: "现在正在导航，用户只是问附近或路上有没有，不是要换目的地，所以没有改路线，导航还在继续。请调用 query_live_info，kind=along_route，查沿途的，然后按结果如实简短回答；用户之后明确说要去那里时再调用 navigate_to。不要说已经开始导航或已经换了路线。",
        .vagueExitWhileNavigating: "导航还在继续，没有结束。用户只是说算了/不用了/不去了，不是要结束导航；用一句话回应并说明导航还在继续、要结束请说结束导航，例如「好的，导航还在继续，要结束请说结束导航。」不要说导航已结束，也不要问要不要结束导航。",
        .speechOutputNotRequested: "用户这句话并没有让你停止说话或恢复说话，所以没有执行，你的说话状态没有改变。不要提这件事，也不要说你会安静或已经安静；简短回应这句话本身，没听清就请他再说一遍。",
        .unsupportedBodyPart: "用户说的是小诺控制不了的部件，所以没有执行，车窗也没有动。请用一句话如实说暂时还不支持，不要说已经做了，也不要改开车窗。",
        .mediaLibraryUnsupported: "control_music 只能放内置曲目，不能放用户说的那首，所以没有播放。用户说了歌名、歌手、作品或描述，请改用 play_music 按描述去放，不要谎称已经播放，也不要改放内置曲目。",
        .notPlaying: "这首没放成，可能需要会员或者有版权限制。请如实说没放成，不要说正在放。",
        .noMusicApp: "手机上没有能播放的音乐 app，请如实说。",
        .handoffRejected: "音乐 app 没有接受这次请求，没有播放。请用一句话如实说没放成，不要说正在放。",
        .musicStillPlaying: "已经让音乐 app 暂停，但它还在放。请如实说音乐还没停，不要说已经关掉了。",
        .musicHandoffUnavailable: "现在不能交给音乐 app 播放，没有播放。请用一句话如实说放不了，不要说正在放。",
        .amapWebKeyMissing: "高德的查询服务还没有配置，所以没有查。请用一句话如实说这个功能还没有配置好（例如「天气查询还没有配置」），不要编造任何结果。",
        .noLocation: "还没有定位，所以查不了这里的情况。请用一句话如实说还没有定位，可以请用户说一个城市名；不要猜一个城市。",
        .noDestination: "现在没有目的地，所以没有查。请用一句话问用户要查哪里，不要猜一个地方。",
        .notNavigating: "现在没有在导航，也没有算好的路线，所以查不了路上的情况。如果用户是在找附近的地点（例如加油站、充电站），马上改用 navigate_to（destination=附近的加油站）搜索，不要说没在导航；否则用一句话如实说现在没有在导航。",
        .liveInfoUnavailable: "这次查询没有拿到结果（超时或服务出错）。请用一句话如实说现在查不到，绝对不要猜测或编造天气、路况或地点信息。",
        .liveInfoQuota: "今天的查询次数已经用完了，没有查到。请用一句话如实告诉用户今天的查询次数用完了，不要编造结果。",
        .noResults: "查询成功，但没有找到结果（category 是要找的东西，若有）。有 message 时就照 message 说（例如「前方10公里沿途没有找到加油站」），否则如实说没有找到，例如「沿途没有找到加油站」，不要编造一个。",
        .invalidKind: "这类实时信息没有数据来源，没有查询。请用一句话如实说无法回答，不要编造。",
        .invalidArgument: "查询参数不对，没有查询。请用一句话问清楚用户要查什么，不要编造结果。",
        .notADriverTurn: "这是导航播报，不需要回应。请不要说任何话。",
        .homeNotSet: "用户还没有设置家的地址，所以没有导航。请用一句话如实说还不知道他家在哪里，请他直接说出地址，不要猜一个地方。",
        .workNotSet: "用户还没有设置公司的地址，所以没有导航。请用一句话如实说还不知道他公司在哪里，请他直接说出地址，不要猜一个地方。",
    ]

    public static let confirmCall = "已经找到联系人，但还没有拨号。请用一句话问用户是否要给这个人打电话；用户确认后，再用 confirmed=true 再调用一次 place_call。不要说已经打了。"
    public static let chooseContact = "有多个联系人符合这个名字，没有拨号。请用一句话请用户说清楚是哪一位，不要自己选一个。"
    public static let climateOff = "设定已经改了，但空调现在是关着的，用户感受不到任何变化。请调用 control_climate{action=power_on} 把空调打开，成功后再用一句话告诉用户；不要直接说已经调好了。"
}
// swiftlint:enable line_length
