import SwiftUI

/// 来电铃声选择：一行一个，点右边喇叭试听（放 4 秒自己停），点一行就是选中
struct RingtonePicker: View {
    @ObservedObject private var ring = Ringtone.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        /* 二级菜单一律**整页 push**（和微信一致）：不再自带 NavigationStack
           （套在外层栈里会变成"两层导航栏、没有返回键"），改用全站那套 NavBar。 */
        VStack(spacing: 0) {
            NavBar(title: Tr("来电铃声"), back: { ring.stop(); dismiss() }) {
                Button { ring.stop(); dismiss() } label: {
                    Text(Tr("完成")).font(pf(15.5, .medium)).foregroundColor(C.green)
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(.plain)
            }
            List {
                Section {
                    ForEach(Ringtone.all) { tone in
                        Button {
                            ring.current = tone.id
                            ring.preview(tone.id)          // 选中顺便试听一下
                        } label: {
                            HStack(spacing: 10) {
                                Text(tone.name).foregroundColor(C.label)
                                Spacer()
                                if ring.previewing == tone.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundColor(C.green)
                                }
                                if ring.current == tone.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(C.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(Tr("来电铃声"))
                } footer: {
                    Text(Tr("点一下切换并试听；铃声是 App 里合成的，声音走外放，手机静音键也听得见。"))
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { ring.stop(); dismiss() }
        .hidesTabBar()
        .onDisappear { ring.stop() }
    }
}
