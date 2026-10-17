import SwiftUI

/* ============================================================
   地区选择（和微信一样）：省 / 市两个滚轮，上下滑着选
   省市表在服务端（/api/regions），一次拉回来；点「完成」把「省 市」写回个人资料。
   ============================================================ */

struct RegionPickerSheet: View {
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [API.RegionRow] = []
    @State private var pi = 0
    @State private var ci = 0

    private var cities: [String] { pi < rows.count ? rows[pi].c : [] }
    private var province: String { pi < rows.count ? rows[pi].p : "" }
    private var city: String { ci < cities.count ? cities[ci] : "" }
    /// 当前选中的「省 市」（省市同名时只留一个）
    private var current: String {
        if province.isEmpty { return "" }
        if city.isEmpty || city == province { return province }
        return province + " " + city
    }

    /// 热门城市：点一下直接跳到那个省 + 那个市（先把省定位出来）
    private let hot = ["北京", "上海", "广州", "深圳", "杭州", "成都", "南京", "武汉", "西安", "重庆"]

    var body: some View {
        /* 整页 push（不再是半屏）：① 顶栏用全站 NavBar；
            ② 一排**热门城市**胶囊，点一下直接就位（不用滚轮滚半天）
            ③ 两个滚轮放进一张圆角玻璃卡里，滚轮的上下两条渐隐遮罩
            ④ 底下一条绿色渐变的「完成」 */
        VStack(spacing: 0) {
            NavBar(title: Tr("选择地区"), back: { dismiss() })
            /* 实时显示当前选中的省市（滚轮一动就跟着变） */
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(C.green)
                Text(current.isEmpty ? Tr("滑动选择，或点下面的热门城市") : current)
                    .font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(hot, id: \.self) { name in
                        Button { jump(to: name) } label: {
                            Text(name)
                                .font(pf(13))
                                .foregroundColor(current.hasSuffix(name) ? .white : C.label)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background {
                                    if current.hasSuffix(name) {
                                        Capsule().fill(C.green)
                                    } else {
                                        Capsule().fill(C.label.opacity(0.06))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                if rows.isEmpty {
                    ProgressView().frame(height: 200)
                } else {
                    HStack(spacing: 0) {
                        Picker("", selection: $pi) {
                            ForEach(0..<rows.count, id: \.self) { i in
                                Text(rows[i].p).tag(i)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .onChange(of: pi) { _ in ci = 0 }

                        Picker("", selection: $ci) {
                            ForEach(0..<max(cities.count, 1), id: \.self) { i in
                                Text(i < cities.count ? cities[i] : "").tag(i)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                    .frame(height: 200)
                    /* 上下两条渐隐：滚轮进出的时候是化开的，不是硬切 */
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 0.84),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .background { CardGlassBox(radius: 16) }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(C.hairline, lineWidth: 0.6))
            .padding(.horizontal, 14)

            Button { done() } label: {
                Text(Tr("完成"))
                    .font(pf(16, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { if rows.isEmpty { rows = await API.shared.regions() } }
    }

    /// 点热门城市：先找它在哪个省，再找市，两个滚轮一起滚过去
    private func jump(to name: String) {
        guard !rows.isEmpty else { return }
        for (i, r) in rows.enumerated() {
            if r.p == name {
                withAnimation(.easeOut(duration: 0.2)) { pi = i; ci = 0 }
                return
            }
            if let j = r.c.firstIndex(of: name) {
                withAnimation(.easeOut(duration: 0.2)) { pi = i; ci = j }
                return
            }
        }
    }

    private func done() {
        guard pi < rows.count else { dismiss(); return }
        onPick(current)
        dismiss()
    }
}
