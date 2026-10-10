// 由 native/scripts/generate-from-electron.mjs 从 Electron 版原样生成，不要手改。

import Foundation

public let PLAN_SYSTEM = #"""
你是资深移动产品经理兼 UI 设计师，负责为中文《软件用户手册》规划手机 App 界面截图。
要求：
1. 根据软件名和用户要求推断合理的领域、目标用户和核心流程，界面必须是这个领域专属的，不要做成能套用到别的产品上的通用模板，也不要七个都是仪表盘变体。
2. 常见领域覆盖参考：
   - 计算/计数：输入、执行、结果、历史、设置
   - 记账：录入、分类、账单列表、统计、预算/提醒、导出
   - 决定/随机/抽签：选项编辑、执行、结果、历史、模板、设置
   - 学习/训练：课程/首页、任务、练习、进度、笔记/收藏、我的
   - 健康/运动：总览、记录录入、计划、趋势、提醒、我的
   - 库存：物品列表、出入库、扫码/搜索、盘点、预警、设置
   - 日程：日历、新建事件、提醒、任务列表、视图切换、设置
   - 识别/文档/翻译：拍摄/导入、识别、可编辑结果、历史、导出分享
   - 地图/出行：搜索、路线/行程、详情、收藏/历史、设置
   - 客户/会员/订单：总览、列表/搜索、详情、新增/编辑、统计、导出/设置
   - 游戏：开始/主菜单、关卡/模式选择、对局进行中、结算、排行/成就、商店/角色、设置
3. 屏数优先按用户指定；未指定时以 7 屏为兜底，按功能覆盖增减（5–10 屏），并在 coverageReason 里说明理由。7 屏兜底顺序：入口/引导 → 主页总览 → 核心设置或输入 → 核心操作或查询 → 记录或列表 → 详情/结果/回执 → 我的/设置/收尾。
4. 每屏有独立的状态、操作、反馈和目的，顺序可导航、可信。界面标签简短，示例数据具体且属于该领域；同一对象在不同屏的数值必须一致。
5. 截图界面里绝对不能出现软件名、App 名、版本号、名称型 logo 或 wordmark；导航标签、页面标题、示例数据里都不要包含软件名或其中可识别的品牌词。设置页、我的页不要出现「关于本软件」「当前版本」「检查更新」这类会显示版本号的条目。
6. title 是界面中文名（用于图注，如「运营总览首页」），2–12 个字，各屏不重复。
7. visualBrief 用英文写给生图模型（120–260 个英文单词），描述该屏的具体布局、组件、状态和需要出现的中文界面文字（中文原样写在英文句子里），要具体到卡片、按钮、数值。
8. uiContract 是所有屏共享的视觉约束：visualStyle（英文短语）、palette（primary/background/surface/text 必填，可加 muted/warning/success/danger，均为 #RRGGBB）、typography、radius、shadow、density、navigation（type 取 bottom-tabs / stack / none，labels 为底部导航中文标签，iconSemantics 为英文图标含义）。
9. textContract 用中文写：entry 从哪里进入、action 主要操作、feedback 成功反馈、exception 异常处理、exit 下一步/返回。
"""#

public let GATE_SYSTEM = #"""
你是严格的移动 App 截图验收员。逐字查看截图，回答：
- singleScreen：是否只有一个完整的手机界面（不是拼图、不是多屏、不是设计稿合集）。
- portraitApp：是否是竖屏 App 界面本身（不是带实体手机外壳/边框的效果图、不是海报）。
- brandFound：界面里是否出现了下面列出的任何禁词，或者明显表示这些禁词的 logo / wordmark / 艺术字。只看图上真实可见的内容，看不清的不要猜。
- brandEvidence：如果 brandFound 为 true，写出看到的文字和位置。
- screenTitle：界面顶部标题。
- visibleText：图上所有清晰可读的文字，逐条原样抄录（最多 80 条）。
- inventory：用中文详细描述这个界面上可见的区域、控件、数据和状态（谁在哪、显示了什么数值），供后续写说明文字用，200–500 字。
- warnings：非阻断的问题，例如中文乱码或错字、文字重叠截断、出现安卓导航栏（要求 iPhone 时）、实体手机外壳、内容过于稀疏、和其他屏风格明显不一致、日期过旧等。没有就给空数组。
"""#

public let CONTENT_SYSTEM = #"""
你是中文软件用户手册撰写专家，为手机 App 的《用户手册》写正文。
规则：
1. 封面介绍 overview：180–300 个字符，说明软件定位、目标用户、核心模块和整体使用流程，领域专属；禁止「进入软件、查看首页、执行核心操作、整理记录、查看统计到管理个人设置」这类通用骨架句。
2. 每屏功能说明 text：至少 {floor} 个字符（按普通字符串长度计，不是只数汉字），建议 330–450 个字符；描述该屏可见的数据、控件、操作步骤、反馈与校验、异常处理、与下一界面或返回的衔接。必须与截图实际内容一致（以「截图实际内容」为准，计划里有但截图没有的不要写）。
3. 各屏正文独立，不要套话复用，不要写同样的结尾。
4. 任何地方都不要出现「图1」「图2」这类「图+数字」字样。
5. 不要说这是虚构、示例或假想的软件；不要提到截图、AI、生成。
6. 简体中文，可分 1–3 段（用换行分隔）。title 用计划里的界面标题，除非截图标题明显不同。
"""#

public let DESIGN_SYSTEM = #"""
你为中文软件用户手册撰写「软件设计说明」章节，内容要和给出的规划一致、领域专属，不臆造厂商或实现细节。
按顺序输出五节：
1. 软件基本处理流程：入口、校验、核心操作、持久化、反馈、退出或恢复。
2. 程序系统组织结构：表现层、应用/服务层、领域层、数据访问层、集成职责。
3. 功能模块划分：把功能规划划分为内聚模块，说明职责和交互。
4. 接口设计：只写领域或用户要求支持的内部/外部接口，说明用途、输入、输出、错误。
5. 数据结构设计：核心实体、标识、关系、状态字段、时间戳、保留策略。
每节 250–600 字，可用换行分段；不要出现「图N」字样，不要说软件是虚构的。
"""#

public let FEEDBACK_SYSTEM = #"""
你负责把用户对一个《软件用户手册》项目提的多条修改意见整理成具体的修改动作。手册由若干张手机 App 截图和每张图的说明文字组成，图N 就是第 N 张截图。
动作类型：
- image：要改截图画面本身（颜色、布局、控件、图上的文字和数据、风格）。target 写 screen-XX；所有截图都要改时 target 写 all。图改了以后，这一屏的说明会自动按新图重写，不需要再加 text 动作，除非用户对文字另有要求。
- text：只改某一屏的说明文字（内容侧重、补充什么、删掉什么、措辞），不改图。target 写 screen-XX。
- overview：改封面介绍。target 写 overview。
- design：改「软件设计说明」章节。target 写 design。
- replan：要增加或删除界面、改屏数、整体换功能方向。target 写 all。有 replan 时所有截图和说明都会重做，不要再给其他屏单独出 image / text 动作。
规则：
1. 同一屏、同一类型只出一个动作；多条意见说的是同一屏同一件事时合并，instruction 里把要求写全。
2. instruction 用中文，写清楚改什么、怎么改，以及哪些保持不变；不要扩大用户没提到的修改范围。
3. items 写这个动作来自哪几条意见（意见编号）。每条意见至少出现在一个动作或一个问题里。
4. 说不清改哪一屏、意见之间互相矛盾、或者需要用户做决定的，放进 questions，不要猜。
5. summary 用一两句话概括这次要改什么。
"""#

public let PROMPT_EDIT_SYSTEM = #"""
你负责按修改要求改写一份手机 App 截图的生图提示词（英文为主，界面上的中文原样保留）。
规则：
1. 只改修改要求涉及的部分，其余描述（尺寸、状态栏、配色、导航、示例数据等）保持原样，输出完整的新提示词。
2. 修改要求是中文的，改写进提示词时用英文描述，界面上要出现的中文文字原样写。
3. 原提示词里说明「不能在界面上显示软件名」的句子必须保留；不要在别处新增软件名、App 名、版本号、logo。
"""#

public let PLAN_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "profile",
    "coverageReason",
    "features",
    "uiContract",
    "screens"
  ],
  "properties": {
    "profile": {
      "type": "object",
      "required": [
        "domain",
        "targetUser",
        "coreFlow"
      ],
      "properties": {
        "domain": {
          "type": "string",
          "minLength": 2
        },
        "targetUser": {
          "type": "string",
          "minLength": 2
        },
        "coreFlow": {
          "type": "string",
          "minLength": 2
        }
      }
    },
    "coverageReason": {
      "type": "string",
      "minLength": 4
    },
    "features": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": [
          "name",
          "screenId"
        ],
        "properties": {
          "name": {
            "type": "string"
          },
          "screenId": {
            "type": "string"
          },
          "tier": {
            "type": "string"
          }
        }
      }
    },
    "uiContract": {
      "type": "object",
      "required": [
        "visualStyle",
        "palette",
        "typography",
        "navigation"
      ],
      "properties": {
        "visualStyle": {
          "type": "string"
        },
        "palette": {
          "type": "object",
          "required": [
            "primary",
            "background",
            "surface",
            "text"
          ]
        },
        "typography": {
          "type": "string"
        },
        "radius": {
          "type": "string"
        },
        "shadow": {
          "type": "string"
        },
        "density": {
          "type": "string"
        },
        "navigation": {
          "type": "object",
          "required": [
            "type",
            "labels"
          ],
          "properties": {
            "type": {
              "type": "string"
            },
            "labels": {
              "type": "array",
              "items": {
                "type": "string"
              }
            },
            "iconSemantics": {
              "type": "array",
              "items": {
                "type": "string"
              }
            }
          }
        }
      }
    },
    "screens": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": [
          "id",
          "title",
          "pageType",
          "mustShow",
          "sampleData",
          "textContract",
          "visualBrief"
        ],
        "properties": {
          "id": {
            "type": "string",
            "pattern": "^screen-\\d{2}$"
          },
          "title": {
            "type": "string",
            "minLength": 2,
            "maxLength": 20
          },
          "pageType": {
            "type": "string"
          },
          "activeTab": {
            "type": [
              "string",
              "null"
            ]
          },
          "mustShow": {
            "type": "array",
            "minItems": 3,
            "items": {
              "type": "string"
            }
          },
          "sampleData": {
            "type": "array",
            "minItems": 2,
            "items": {
              "type": "string"
            }
          },
          "textContract": {
            "type": "object",
            "required": [
              "entry",
              "action",
              "feedback",
              "exception",
              "exit"
            ],
            "properties": {
              "entry": {
                "type": "string"
              },
              "action": {
                "type": "string"
              },
              "feedback": {
                "type": "string"
              },
              "exception": {
                "type": "string"
              },
              "exit": {
                "type": "string"
              }
            }
          },
          "visualBrief": {
            "type": "string",
            "minLength": 120
          }
        }
      }
    }
  }
}
"""#)

public let GATE_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "singleScreen",
    "portraitApp",
    "brandFound",
    "visibleText",
    "inventory",
    "warnings"
  ],
  "properties": {
    "singleScreen": {
      "type": "boolean"
    },
    "portraitApp": {
      "type": "boolean"
    },
    "brandFound": {
      "type": "boolean"
    },
    "brandEvidence": {
      "type": "string"
    },
    "screenTitle": {
      "type": "string"
    },
    "visibleText": {
      "type": "array",
      "items": {
        "type": "string"
      }
    },
    "inventory": {
      "type": "string",
      "minLength": 20
    },
    "warnings": {
      "type": "array",
      "items": {
        "type": "string"
      }
    }
  }
}
"""#)

public let CONTENT_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "screens"
  ],
  "properties": {
    "overview": {
      "type": "string"
    },
    "screens": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "id",
          "title",
          "text"
        ],
        "properties": {
          "id": {
            "type": "string"
          },
          "title": {
            "type": "string"
          },
          "text": {
            "type": "string"
          }
        }
      }
    }
  }
}
"""#)

public let DESIGN_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "sections"
  ],
  "properties": {
    "sections": {
      "type": "array",
      "minItems": 3,
      "items": {
        "type": "object",
        "required": [
          "title",
          "text"
        ],
        "properties": {
          "title": {
            "type": "string"
          },
          "text": {
            "type": "string",
            "minLength": 120
          }
        }
      }
    }
  }
}
"""#)

public let FEEDBACK_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "summary",
    "actions",
    "questions"
  ],
  "properties": {
    "summary": {
      "type": "string"
    },
    "actions": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "type",
          "target",
          "instruction",
          "items"
        ],
        "properties": {
          "type": {
            "type": "string",
            "enum": [
              "image",
              "text",
              "overview",
              "design",
              "replan"
            ]
          },
          "target": {
            "type": "string"
          },
          "instruction": {
            "type": "string",
            "minLength": 2
          },
          "items": {
            "type": "array",
            "items": {
              "type": "integer"
            }
          }
        }
      }
    },
    "questions": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "question",
          "items"
        ],
        "properties": {
          "question": {
            "type": "string"
          },
          "items": {
            "type": "array",
            "items": {
              "type": "integer"
            }
          }
        }
      }
    }
  }
}
"""#)

public let PROMPT_EDIT_SCHEMA: JSON = try! JSON.parse(#"""
{
  "type": "object",
  "required": [
    "prompt"
  ],
  "properties": {
    "prompt": {
      "type": "string",
      "minLength": 200
    }
  }
}
"""#)

public let FEEDBACK_TYPES = ["image","text","overview","design","replan"]
