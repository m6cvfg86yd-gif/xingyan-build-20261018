import SwiftUI

/* 四个首页的顶栏 / 底栏文字：后台能改（tabTitle0-3）；
   界面语言切成 English 时用英文默认值，后台自己填过的中文仍然优先。 */
extension C {
    static var tabText0: String { Lang.isEnglish ? UIConfig.text("tabTitle0en", "Chats") : C.tabTitle0 }
    static var tabText1: String { Lang.isEnglish ? UIConfig.text("tabTitle1en", "Contacts") : C.tabTitle1 }
    static var tabText2: String { Lang.isEnglish ? UIConfig.text("tabTitle2en", "Discover") : C.tabTitle2 }
    static var tabText3: String { Lang.isEnglish ? UIConfig.text("tabTitle3en", "Me") : C.tabTitle3 }
}
