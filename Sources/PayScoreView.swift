import SwiftUI

/* ============================================================
   支付分（微信「我 → 服务 → 钱包 → 支付分」那页）
   · 上面一个大分数 + 等级 + 分数区间刻度
   · 三个维度：身份特质 / 支付行为 / 履约记录（进度条 + 一句说明 + 怎么提升）
   · 免押服务：够分显示「可免押」，不够显示「还差 N 分」
   · 分值变化记录
   ============================================================ */
struct PayScoreView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var data: API.PayScore?
    @State private var loading = true

    private var score: Double { data?.score ?? 0 }
    private var levelColor: Color {
        if score >= 700 { return C.green }
        if score >= 600 { return Color(hex: 0x2AAE67) }
        return C.orange
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("支付分"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    /* 大分数 */
                    VStack(spacing: 6) {
                        Text(loading ? "…" : String(Int(score)))
                            .font(pfMoney(52, .medium))
                            .foregroundColor(.white)
                        Text(data?.level ?? "")
                            .font(pf(15, .medium))
                            .foregroundColor(.white)
                        if let d = data {
                            Text(Tr("分数区间 ") + "\(Int(d.min)) - \(Int(d.max))")
                                .font(pf(12))
                                .foregroundColor(Color.white.opacity(0.85))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(LinearGradient(colors: [levelColor, levelColor.opacity(0.75)],
                                               startPoint: .top, endPoint: .bottom))

                    /* 五项维度（2026-10-16 重排：规则由甲方定，权重直接标在名字后面） */
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("分是怎么来的")).font(pf(13)).foregroundColor(C.subLabel)
                            .padding(.horizontal, 8).padding(.bottom, 6)
                        GroupCard {
                            let dims = data?.dims ?? []
                            ForEach(Array(dims.enumerated()), id: \.element.id) { idx, d in
                                if idx > 0 { HairLine(inset: 16) }
                                dimRow(d)
                            }
                        }
                        if let f = data?.formula, !f.isEmpty {
                            Text(Tr("规则：") + f)
                                .font(pf(12)).foregroundColor(C.subLabel)
                                .padding(.horizontal, 10).padding(.top, 8)
                        }
                        if let t = data?.updatedAt, !t.isEmpty {
                            Text(Tr("更新时间：") + rpTime(t) + Tr("　（每月 1 号重算，行为变了分数会跟着变）"))
                                .font(pf(11.5)).foregroundColor(C.subLabel)
                                .padding(.horizontal, 10).padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 12)

                    /* 免押服务 */
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("凭支付分可以免押")).font(pf(13)).foregroundColor(C.subLabel)
                            .padding(.horizontal, 8).padding(.bottom, 6)
                        GroupCard {
                            let list = data?.services ?? []
                            if list.isEmpty {
                                Text(Tr("暂时没有可用服务")).font(pf(14)).foregroundColor(C.subLabel)
                                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                            } else {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, s in
                                    if idx > 0 { HairLine(inset: 16) }
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(s.name).font(pf(15.5)).foregroundColor(C.label)
                                            Text(s.desc ?? "").font(pf(12)).foregroundColor(C.subLabel)
                                        }
                                        Spacer(minLength: 6)
                                        if s.ok == true {
                                            Text(Tr("可免押")).font(pf(13, .medium)).foregroundColor(C.green)
                                        } else {
                                            Text(Tr("还差 ") + "\(Int(s.gap ?? 0))" + Tr(" 分"))
                                                .font(pf(13)).foregroundColor(C.subLabel)
                                        }
                                    }
                                    .padding(.horizontal, 16).frame(height: 60)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 14)

                    /* 分值变化 */
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("最近的分值变化")).font(pf(13)).foregroundColor(C.subLabel)
                            .padding(.horizontal, 8).padding(.bottom, 6)
                        GroupCard {
                            let list = data?.history ?? []
                            if list.isEmpty {
                                Text(Tr("还没有记录")).font(pf(14)).foregroundColor(C.subLabel)
                                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                            } else {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, h in
                                    if idx > 0 { HairLine(inset: 16) }
                                    HStack(spacing: 10) {
                                        Text(h.text).font(pf(15)).foregroundColor(C.label)
                                        Spacer(minLength: 6)
                                        Text((h.delta >= 0 ? "+" : "") + "\(Int(h.delta))")
                                            .font(pfMoney(15))
                                            .foregroundColor(h.delta >= 0 ? C.green : C.red)
                                        Text(rpTime(h.at))
                                            .font(pf(11.5)).foregroundColor(C.subLabel)
                                    }
                                    .padding(.horizontal, 16).frame(height: 50)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 14)

                    Text(data?.note ?? "")
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 14)
                    Color.clear.frame(height: 26)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            data = try? await API.shared.payScore()
            loading = false
        }
    }

    private func dimRow(_ d: API.PayScoreDim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(d.name).font(pf(15.5, .medium)).foregroundColor(C.label)
                if let w = d.max {
                    Text(Tr("满分 ") + "\(Int(w))").font(pf(11.5)).foregroundColor(C.subLabel)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Capsule().fill(C.hairline))
                }
                Spacer(minLength: 6)
                /* 拿到的分 / 满分（比原来只写一个 0~100 的数直观得多） */
                if let p = d.points, let m = d.max {
                    Text(moneyTrim(p) + " / " + moneyTrim(m))
                        .font(pfMoney(15))
                        .foregroundColor(scoreColor(p, m))
                } else {
                    Text("\(Int(d.value))").font(pfMoney(15)).foregroundColor(C.subLabel)
                }
            }
            /* 进度条 */
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(C.hairline).frame(height: 6)
                    Capsule().fill(scoreColor(d.points ?? d.value, d.max ?? 100))
                        .frame(width: max(6, geo.size.width * CGFloat(max(0, min(100, d.value)) / 100)), height: 6)
                }
            }
            .frame(height: 6)
            Text(d.desc ?? "").font(pf(12)).foregroundColor(C.subLabel)
            if let tip = d.tip, !tip.isEmpty {
                Text(Tr("怎么提升：") + tip).font(pf(12)).foregroundColor(C.green.opacity(0.9))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 这一项拿到的分占满分的比例 → 颜色（低了发黄、空了发红，一眼看出该补哪一项）
    private func scoreColor(_ got: Double, _ full: Double) -> Color {
        let r = full <= 0 ? 1 : got / full
        if r >= 0.8 { return C.green }
        if r >= 0.5 { return Color(hex: 0xE9A400) }
        return C.orange
    }

    private func moneyTrim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return abs(r - r.rounded()) < 0.001 ? String(Int(r)) : String(format: "%.1f", r)
    }
}
