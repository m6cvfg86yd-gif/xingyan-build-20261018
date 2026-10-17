import SwiftUI

/* 「请先完成实名认证」整页提示。
   强制实名（和微信一样）：没实名的账号进不了钱包 / 零钱，
   服务端直接 403 + needRealName，这里给一张干净的提示页（不显示任何金额）。 */
struct NeedRealNameView: View {
    var onClose: () -> Void
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("提示"), back: { onClose() })
            VStack(spacing: 14) {
                Spacer(minLength: 30)
                SVGIcon(markup: I.newFriends, size: 46, color: C.green)
                Text(Tr("根据国家规定，请先完成实名认证"))
                    .font(pf(16.5, .medium))
                    .foregroundColor(C.label)
                Text(Tr("完成实名认证后才能使用钱包、零钱、转账、红包、收付款和提现。聊天、通话、朋友圈都不受影响。"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
                Button {
                    RealNameGate.shared.prompt()
                } label: {
                    Text(Tr("去实名认证"))
                        .font(pf(16, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.green))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 34)
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        /* 2026-10-16：实名提示页补左滑返回 */
        .swipeBack { onClose() }
    }
}
