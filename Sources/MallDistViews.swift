import SwiftUI

/* ============================================================
   分销 + 裂变的界面（2026-10-16 用户：「做下一步」）

   服务端早就做好了，这页把 App 那半接上：
     · DistMeView   分销员自己看的：推广码 / 复制 / 分享给好友 / 帮好友助力 / 业绩明细
     · DistAdminCard 管理页那张：开通关闭分销、设佣金比例、业绩榜
   规则：带推广码下单 → 记在分销员名下；签收结算佣金进零钱；退款扣回；邀满 3 人解锁大额券。
   ============================================================ */

struct DistMeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var me: API.DistMe?
    @State private var loading = true
    @State private var codeInput = ""
    @State private var busy = false
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的推广"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if loading {
                        Text(Tr("正在加载…")).font(pf(13)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else if me?.on != true {
                        notOnCard
                    } else {
                        codeCard
                        statCard
                        helpCard
                        logCard
                    }
                    Spacer().frame(height: 20)
                }
                .padding(.horizontal, 12).padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(isPresented: $showShare) {
            if let c = me?.code, !c.isEmpty {
                ShareSheet(items: [shareText(c)])
            }
        }
    }

    private func shareText(_ code: String) -> String {
        "我在星言商城领券买东西，用我的码「" + code + "」进店，你我能各得一张券～"
    }

    private var notOnCard: some View {
        VStack(spacing: 8) {
            Text(Tr("这个账号还不是分销账号")).font(pf(15, .medium)).foregroundColor(C.label)
            Text(Tr("让管理员在「管理 → 商城后台 → 分销」里给你开通，就能拿推广码赚佣金了。"))
                .font(pf(12.5)).foregroundColor(C.subLabel).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(20)
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var codeCard: some View {
        VStack(spacing: 10) {
            Text(Tr("我的推广码")).font(pf(12.5)).foregroundColor(C.subLabel)
            Text(me?.code ?? "")
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundColor(C.label)
                .textSelection(.enabled)
            Text(Tr("佣金比例 ") + String(Int(((me?.rate ?? 0.05) * 100).rounded())) + "%"
                 + Tr("　·　别人带这个码下单，签收后佣金进零钱"))
                .font(pf(12)).foregroundColor(C.subLabel)
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = me?.code ?? ""
                    app.show(Tr("推广码已复制"))
                } label: {
                    Text(Tr("复制推广码")).font(pf(14, .medium)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(Capsule().fill(C.green))
                }
                .buttonStyle(.plain)
                Button { showShare = true } label: {
                    Text(Tr("分享给好友")).font(pf(14, .medium)).foregroundColor(C.link)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(Capsule().stroke(C.link.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16).frame(maxWidth: .infinity)
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statCard: some View {
        HStack(spacing: 0) {
            stat(Tr("累计佣金"), "¥" + moneyFmt(me?.earned ?? 0))
            stat(Tr("推广成交"), String(me?.orders ?? 0) + Tr(" 单"))
            stat(Tr("待结算"), String(me?.pending ?? 0) + Tr(" 单"))
        }
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(pf(17, .semibold)).foregroundColor(C.label)
            Text(t).font(pf(11.5)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
    }

    /* 帮好友助力：把好友的码粘贴进来就能领券（券也是裂变那套：双方各得一张） */
    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Tr("帮好友助力")).font(pf(15, .medium)).foregroundColor(C.label)
            Text(Tr("把好友的推广码粘进来，你和他各得一张券（每人每天最多帮 3 个人）。"))
                .font(pf(12)).foregroundColor(C.subLabel)
            HStack(spacing: 8) {
                TextField(Tr("好友的推广码"), text: $codeInput)
                    .font(pf(14)).autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                Button { Task { await help() } } label: {
                    Text(busy ? Tr("处理中…") : Tr("助力")).font(pf(14, .medium)).foregroundColor(.white)
                        .padding(.horizontal, 16).frame(height: 42)
                        .background(Capsule().fill(busy ? C.subLabel : DDColor.redDeep))
                }
                .buttonStyle(.plain).disabled(busy)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("佣金明细")).font(pf(15, .medium)).foregroundColor(C.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            let rows = me?.log ?? []
            if rows.isEmpty {
                Text(Tr("还没有记录")).font(pf(13)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                ForEach(rows) { r in
                    HairLine(inset: 16)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.text).font(pf(13.5)).foregroundColor(C.label).lineLimit(2)
                            Text(rpTime(r.at)).font(pf(11.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                        Text((r.amount >= 0 ? "+" : "") + moneyFmt(r.amount))
                            .font(pf(14, .medium))
                            .foregroundColor(r.amount >= 0 ? C.green : DDColor.redDeep)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() async {
        me = await API.shared.distMe()
        loading = false
    }

    private func help() async {
        let c = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { app.show(Tr("先填好友的推广码")); return }
        busy = true
        let r = await API.shared.mallAdInvite(code: c)
        busy = false
        if let r = r {
            let mine = r.mine?.title ?? Tr("助力券")
            app.show(Tr("助力成功，你得了一张「") + mine + "」")
            /* 记下这个码：**之后 30 天里**在这台手机下单都算这位好友的推广（佣金归他） */
            UserDefaults.standard.set(c, forKey: "chris.mall.ref")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "chris.mall.refAt")
            codeInput = ""
            await load()
        } else {
            app.show(Tr("助力失败：码不对、重复助力，或者今天次数用完了"))
        }
    }
}

/* ---------------- 管理页：分销 ---------------- */

struct DistAdminCard: View {
    @EnvironmentObject private var app: AppState

    @State private var rows: [API.DistRow] = []
    @State private var who = ""
    @State private var rate = "5"
    @State private var loading = true
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(Tr("分销")).font(pf(16, .semibold)).foregroundColor(C.label)
                Text(Tr("开通 / 佣金比例 / 业绩")) .font(pf(12)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Button { Task { await load() } } label: {
                    Text(Tr("刷新")).font(pf(12.5)).foregroundColor(C.link)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            HStack(spacing: 8) {
                TextField(Tr("账号或用户ID"), text: $who)
                    .font(pf(14)).autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                TextField(Tr("佣金%"), text: $rate)
                    .font(pf(14)).keyboardType(.decimalPad)
                    .frame(width: 66).padding(.horizontal, 8).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                Button { Task { await setDist(true) } } label: {
                    Text(Tr("开通")).font(pf(14, .medium)).foregroundColor(.white)
                        .padding(.horizontal, 14).frame(height: 42)
                        .background(Capsule().fill(C.green))
                }
                .buttonStyle(.plain).disabled(busy)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)

            if loading {
                Text(Tr("正在加载…")).font(pf(13)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else if rows.isEmpty {
                Text(Tr("还没有分销账号。上面填账号 → 点「开通」。"))
                    .font(pf(12.5)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                ForEach(rows) { r in
                    HairLine(inset: 16)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name ?? "").font(pf(14.5, .medium)).foregroundColor(C.label)
                            Text(Tr("码 ") + (r.code ?? "") + Tr("　比例 ")
                                 + String(Int(((r.rate ?? 0.05) * 100).rounded())) + "%"
                                 + Tr("　成交 ") + String(r.orders ?? 0) + Tr(" 单"))
                                .font(pf(11.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                        Text("¥" + moneyFmt(r.earned ?? 0))
                            .font(pf(14, .medium)).foregroundColor(C.green)
                        Button { Task { await setDist(false, r) } } label: {
                            Text(Tr("停")).font(pf(12.5)).foregroundColor(DDColor.redDeep)
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(Capsule().stroke(C.hairline, lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task { await load() }
    }

    private func load() async {
        rows = await API.shared.opsDistList()
        loading = false
    }

    private func setDist(_ on: Bool, _ row: API.DistRow? = nil) async {
        let target = row?.userId ?? who.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { app.show(Tr("先填账号或用户ID")); return }
        busy = true
        let ok = await API.shared.opsDistSet(userId: target, on: on,
                                             rate: (Double(rate) ?? 5) / 100)
        busy = false
        if ok {
            app.show(on ? Tr("已开通分销") : Tr("已停止分销"))
            who = ""
            await load()
        } else {
            app.show(Tr("没成功：账号不存在或没权限"))
        }
    }
}
