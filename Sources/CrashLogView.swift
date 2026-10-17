import SwiftUI

/* 上次崩溃：App 崩过的话，下次打开自动弹这一页 —— 直接截图发我就能定位。
   （不用连电脑、不用看 Xcode 日志） */
struct CrashLogView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("上次崩溃信息"), back: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Tr("把这一页截图发给我，就能定位到崩在哪一行。"))
                        .font(pf(13)).foregroundColor(C.subLabel)
                    Text(UserDefaults.standard.string(forKey: "chris.lastCrashAt") ?? "")
                        .font(pf(12)).foregroundColor(C.subLabel)
                    Text(UserDefaults.standard.string(forKey: "chris.lastCrash") ?? "（没有记录）")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(C.label)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .background(C.cardBg)

            Button {
                UserDefaults.standard.removeObject(forKey: "chris.lastCrash")
                UserDefaults.standard.removeObject(forKey: "chris.lastCrashAt")
                dismiss()
            } label: {
                Text(Tr("已截图，清掉这条"))
                    .font(pf(16, .medium))
                    .foregroundColor(C.green)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(C.cardBg)
            }
            .buttonStyle(.plain)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }
}
