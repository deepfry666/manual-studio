import Foundation

// MARK: - 内容红线
//
// 不涉及危害国家安全、涉政敏感、低俗色情、赌博、暴力血腥；不涉及政府职能（软件不替政府部门办事）。
// 写进规划、生图提示词、正文和设计说明；生成后再按关键词复核，有问题反馈给大模型重写。

public let RED_LINE_RULE = """


内容红线（必须遵守，优先于其他要求）：
1. 不出现危害国家安全、涉政敏感、低俗、色情、裸露、赌博博彩、暴力血腥、毒品枪支等内容。
2. 不涉及政府职能：软件不代替政府部门办事。不写申报、审批、缴纳罚款、办理退税、提取公积金、官方查询，不写对接政府系统或官方数据。
3. 不出现国徽、警徽、党徽、政府机关的名称或标志，不出现"官方"字样，不冒充政务平台。
4. 名称涉及个税、社保、医保、公积金、违章、罚款、户籍、学历等的软件，定位成个人自用的计算、记录、提醒、整理工具：可以写"试算""记录""提醒""对照说明"，不写"在线申报""缴纳""办理""提取到账"。
"""

/// 生图提示词里的红线（英文写给生图模型）
public let RED_LINE_IMAGE_RULE = "Content limits: no national emblem, police badge, party emblem, government agency names or logos, no 'official' badges, no political content; no nudity, sexual or vulgar imagery, gambling, violence or gore. Government-related topics must look like a personal calculator / record / reminder tool, never an official government service (no filing, payment of fines, or official submission screens)."

private let GOV_BODIES = ["政府", "政务", "国务院", "税务局", "税务机关", "社保局", "人社局", "人力资源和社会保障局", "医保局", "公安", "派出所", "交警", "车管所", "交管局", "法院", "检察院", "民政局", "住建局", "公积金中心", "公积金管理中心", "市场监管局", "国徽", "警徽", "党徽", "一网通办", "电子税务局", "个人所得税App", "交管12123", "学信网", "政务服务"]
private let OFFICIAL_TERMS = ["官方平台", "官方数据", "官方渠道", "官方认证", "官方接口", "官方系统", "官方查询", "官方入口"]
private let GOV_ACTIONS = ["在线申报", "网上申报", "一键申报", "提交申报", "申报提交", "确认申报", "申报成功", "办理退税", "退税到账", "退税申请", "缴纳罚款", "罚款缴纳", "在线缴纳罚款", "提取公积金", "公积金提取", "提取到账", "处罚决定", "行政处罚", "审批办结"]
private let VULGAR_TERMS = ["色情", "裸体", "裸露", "约炮", "成人视频", "黄色网站", "赌博", "博彩", "下注", "赌场", "毒品", "枪支", "颠覆", "分裂国家", "邪教", "台独", "藏独", "疆独", "反华"]

/// 文字里碰到红线的词（去重）
public func redLineHits(_ texts: [String]) -> [String] {
    let joined = texts.joined(separator: "\n")
    return uniqued((GOV_BODIES + OFFICIAL_TERMS + GOV_ACTIONS + VULGAR_TERMS).filter { joined.contains($0) })
}

/// 程序复核：交给大模型的反馈
public func redLineProblems(_ label: String, _ texts: [String]) -> [String] {
    let hits = redLineHits(texts)
    return hits.isEmpty ? [] : ["\(label)里出现了红线内容：\(hits.prefix(8).joined(separator: "、"))。不涉及政府职能和官方机构，不写申报、缴纳、办理、官方等；软件定位成个人自用的计算、记录、提醒工具，请改写这些地方"]
}

/// 软件名里带这些字样时，新建页提醒一下（不拦）
public func softwareNameRedLineHint(_ name: String) -> String? {
    let words = ["政务", "政府", "公安", "税务局", "社保局", "人社局", "法院", "检察院", "派出所", "交警", "车管所", "官方"]
    let hits = words.filter { name.contains($0) }
    guard !hits.isEmpty else { return nil }
    return "名称里有「\(hits.joined(separator: "、"))」，可能被认为涉及政府职能。软件会把它写成个人自用的工具，不写办事、申报和官方字样；最好换个名称。"
}

// MARK: - 正文写法：写怎么用，不抄界面

public let CONTENT_STYLE_RULE = """


写法要求（优先于上面「建议 330–450 个字符」和「描述可见数据、控件」的说法）：
1. 每屏写这个界面能做什么、怎么操作、操作后有什么结果、出错怎么处理，以及从哪里进来、点什么去下一步。「截图实际内容」只用来保证说法和画面一致，不要照着它逐项念。
2. 颜色和位置只在需要告诉用户「点哪里」时才写，一屏最多两三处；不写「蓝色胶囊」「浅灰圆角卡片」「白色对勾」这类外观描述。
3. 数字只举一两个说明用途，不把屏幕上的数字逐个抄一遍。
4. 底部导航栏、标签栏不写，除非这一屏讲的就是导航。
5. 不写自我核对的句子（如「两项之和与合计一致」），不写配色、圆角、风格这类话。
6. 篇幅 300–400 个字符为宜，不要超过 450 个字符。
"""

private let COLOR_WORD = #"[蓝绿红橙紫灰白黑黄青粉金银]色"#
private let POSITION_WORD = #"左上角|右上角|左下角|右下角|顶部|底部|左侧|右侧"#

/// 程序复核：写得太长、颜色位置太多、写导航栏、写自我核对的，反馈给大模型精简。
public func contentStyleProblems(_ screens: [JSON]) -> [String] {
    var problems: [String] = []
    for screen in screens {
        let id = screen["id"].text
        let text = screen["text"].text
        let title = screen["title"].text
        var notes: [String] = []
        if text.count > 450 { notes.append("有 \(text.count) 个字符，精简到 300–400") }
        let colors = Rx.matches(COLOR_WORD, text).count
        if colors > 3 { notes.append("写了 \(colors) 处颜色，最多两三处") }
        let positions = Rx.matches(POSITION_WORD, text).count
        if positions > 4 { notes.append("写了 \(positions) 处位置，只留点哪里需要的") }
        if !title.contains("导航"), Rx.test(#"底部(?:四项|三项|五项)?(?:导航|标签栏)|标签栏|导航栏"#, text) { notes.append("不写底部导航栏") }
        if Rx.test(#"之和与|与汇总一致|与合计一致|相加等于"#, text) { notes.append("不写自我核对的句子") }
        if !notes.isEmpty { problems.append("\(id) 的说明：\(notes.joined(separator: "；"))。改成写这一屏怎么用") }
    }
    return problems
}
