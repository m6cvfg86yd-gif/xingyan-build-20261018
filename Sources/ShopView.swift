import SwiftUI

/* ============================================================
   小店（2026-10-12 加，入口：我 → 小店与卡包）

     · 上面是零钱余额，下面是商品列表（图 / 名字 / 价格 / 库存，标出实物还是虚拟）
     · 点一件 → 商品详情 → 「立即购买」（可改数量、实物填收货地址、有支付密码要输密码）
     · 下单走零钱扣款，成功 toast 一下、回到列表
     · 右上角「我的订单」：待发货 / 已发货 / 已完成 + 金额 + 时间

   接口：GET /api/shop（商品 + 我的订单 + 余额）、POST /api/shop/order（下单）。
   商品的上架 / 改价 / 库存 / 排序在「管理」页（UserManageView 里那一块）。
   ============================================================ */

struct ShopView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [API.ShopItem] = []
    @State private var orders: [API.ShopOrder] = []
    @State private var balance: Double = 0
    @State private var loading = true
    @State private var errText = ""
    /// 点开的商品（详情 + 下单都在这一页 sheet 里）
    @State private var open: API.ShopItem? = nil
    @State private var showOrders = false
    /// 拼多多风格 H5 商城（2026-10-12 接入）：整页 WebView 打开
    @State private var showMall = false

    private let cols = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("小店"), back: { dismiss() }) {
                Button { showOrders = true } label: {
                    Text(Tr("我的订单"))
                        .font(pf(14.5))
                        .foregroundColor(C.green)
                        .padding(.horizontal, 12).frame(height: 32)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    /* 拼多多风格 H5 商城：一进来最显眼的一行（微信小程序那种入口） */
                    Button { showMall = true } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(hex: 0xFF5A3C), Color(hex: 0xE02A0F)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                Image(systemName: "bag.fill")
                                    .font(.system(size: 19, weight: .semibold)).foregroundColor(.white)
                            }
                            .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(Tr("拼多多商城")).font(pf(16.5, .medium)).foregroundColor(C.label)
                                    Text(Tr("H5")).font(pf(10.5)).foregroundColor(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xE02A0F)))
                                }
                                Text(Tr("拼团 · 秒杀 · 种草 · 购物车（和商城后台同一套数据）"))
                                    .font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Chevron(size: 9, line: 1.6)
                        }
                        .padding(.horizontal, 14).frame(height: 66)
                        .background(C.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    /* ⚠ 2026-10-12 用户要求「不要余额」：小店这一页不再显示零钱余额那张卡。
                       （下单还是照旧走零钱扣款，服务端那套没动，只是页面上不再摆余额。） */

                    if loading && items.isEmpty {
                        ProgressView().padding(.top, 40)
                    } else if items.isEmpty {
                        Text(Tr("店里还没上架商品")).font(pf(14)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                        if !errText.isEmpty {
                            Text(errText).font(pf(12)).foregroundColor(C.subLabel)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 26).padding(.top, 6)
                        }
                    } else {
                        LazyVGrid(columns: cols, spacing: 10) {
                            ForEach(items) { it in
                                Button { open = it } label: { cell(it) }
                                    .buttonStyle(MenuPressStyle())
                            }
                        }
                        .padding(.horizontal, 12)

                        Text(Tr("下单后可以在右上角「我的订单」里看进度。"))
                            .font(pf(12)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.top, 4)
                    }
                    Spacer().frame(height: 30)
                }
                .padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(item: $open) { it in
            ShopItemSheet(item: it, balance: balance) { newBalance in
                balance = newBalance
                Task { await load() }
            }
            .environmentObject(app)
        }
        .sheet(isPresented: $showOrders) {
            ShopOrdersSheet(orders: orders, balance: balance)
                .environmentObject(app)
        }
        /* 拼多多风格 H5 商城：整页打开（改商城只要换服务器上的文件，不用重新出包） */
        .fullScreenCover(isPresented: $showMall) {
            /* ⚠ 2026-10-12 用户要求商城要**原生**：这里也改成原生商城
               （原来这里开的是服务器上的 H5 页面，用户看到的「又是 h5」就是它）。
               H5 那页 MallWebPage.swift 没删，留着备用。 */
            /* 和「我 → 商城」一样：先过授权（MallAuth.swift） */
            MallAuthGate { MallNativeView().environmentObject(app) }
        }
    }

    private var balanceCard: some View {
        GroupCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Tr("零钱余额")).font(pf(14)).foregroundColor(C.subLabel)
                    Text("¥" + moneyFmt(balance))
                        .font(pfMoney(22, .medium)).foregroundColor(C.label)
                }
                Spacer(minLength: 0)
                Image(systemName: "bag.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(C.green.opacity(0.85))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .padding(.top, 2)
    }

    private func cell(_ it: API.ShopItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(C.fieldBg)
                if let img = it.img, !img.isEmpty {
                    RemoteImage(path: img)
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 30))
                        .foregroundColor(C.subLabel)
                }
            }
            .frame(height: 104)

            Text(it.name).font(pf(14.5)).foregroundColor(C.label)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            HStack(spacing: 6) {
                Text("¥" + moneyFmt(it.price))
                    .font(pfMoney(15, .medium)).foregroundColor(C.red)
                Text(it.kindName)
                    .font(pf(10.5))
                    .foregroundColor(C.subLabel)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(C.fieldBg))
                Spacer(minLength: 0)
                Text(Tr("库存 ") + String(it.stock ?? 0))
                    .font(pf(11)).foregroundColor(C.subLabel)
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .padding(8)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity((it.stock ?? 1) <= 0 ? 0.55 : 1)
    }

    private func load() async {
        do {
            let d = try await API.shared.shopData()
            items = d.items ?? []
            orders = d.orders ?? []
            balance = d.balance ?? (app.me?.balance ?? 0)
            errText = ""
            DiagLog.shared.note("小店：拉到 \(items.count) 件商品 / \(orders.count) 个订单")
        } catch {
            errText = (error as? LocalizedError)?.errorDescription ?? "加载失败"
            DiagLog.shared.note("小店：加载失败 \(errText)")
        }
        loading = false
    }
}

/* ---------------------------------------------------------- 商品详情 + 下单 */

struct ShopItemSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let item: API.ShopItem
    let balance: Double
    /// 下单成功后把新的零钱余额交给列表
    let onDone: (Double) -> Void

    @State private var count = 1
    @State private var address = ""
    @State private var showPay = false
    @State private var busy = false

    private var total: Double { item.price * Double(count) }
    private var soldOut: Bool { (item.stock ?? 1) <= 0 }
    /* 价格 / 类型 / 库存那一行：**先在属性里拼好**再交给 Text。
       直接在 ViewBuilder 里拼 7 段字符串，swiftc 的类型检查会爆炸
       （B171 第一次出包就是栽在这儿：ShopView.swift:192 "unable to type-check in reasonable time"）。 */
    private var specText: String {
        let price = Tr("价格") + " ¥" + moneyFmt(item.price)
        let stock = Tr("库存 ") + String(item.stock ?? 0)
        return price + " · " + item.kindName + " · " + stock
    }
    /// 「合计 ¥xx　零钱 ¥xx」
    private var totalText: String {
        Tr("合计 ") + "¥" + moneyFmt(total) + "　" + Tr("零钱 ") + "¥" + moneyFmt(balance)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: item.name, back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if let img = item.img, !img.isEmpty {
                        RemoteImage(path: img)
                            .scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 12)
                    }

                    GroupCard {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(pf(17, .medium)).foregroundColor(C.label)
                                Text(specText)
                                    .font(pf(13)).foregroundColor(C.subLabel)
                                if let d = item.desc, !d.isEmpty {
                                    Text(d).font(pf(13)).foregroundColor(C.subLabel)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)

                        if item.isPhysical {
                            HairLine(inset: 16)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Tr("收货地址")).font(pf(13)).foregroundColor(C.subLabel)
                                TextField(Tr("省市区 + 详细地址 + 手机号"), text: $address, axis: .vertical)
                                    .font(pf(14.5))
                                    .lineLimit(2...4)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }

                        HairLine(inset: 16)
                        HStack(spacing: 12) {
                            Text(Tr("数量")).font(pf(15.5)).foregroundColor(C.label)
                            Spacer(minLength: 0)
                            Button { if count > 1 { count -= 1 } } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(C.label)
                                    .frame(width: 32, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.fieldBg))
                            }
                            .buttonStyle(.plain)
                            Text("\(count)").font(pf(16)).foregroundColor(C.label).frame(minWidth: 26)
                            Button { if count < min(99, item.stock ?? 99) { count += 1 } } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(C.label)
                                    .frame(width: 32, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.fieldBg))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).frame(height: 54)
                    }

                    Text(totalText)
                        .font(pf(13)).foregroundColor(C.subLabel)

                    Button {
                        buy()
                    } label: {
                        Text(soldOut ? Tr("已售罄") : Tr("立即购买"))
                            .font(pf(17, .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(soldOut ? Color.gray : C.green))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || soldOut)
                    .padding(.horizontal, 16)

                    Spacer().frame(height: 30)
                }
                .padding(.top, 12)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        /* 有支付密码的用户：弹六格密码键盘，输满 6 位自动下单 */
        .sheet(isPresented: $showPay) {
            ShopPaySheet(amount: total, item: item.name) { pwd in
                await submit(payPassword: pwd)
            }
            .environmentObject(app)
        }
        /* 2026-10-16 用户：「好多东西无法左滑返回」——商品详情补上左边缘右滑返回 */
        .swipeBack { dismiss() }
    }

    private func buy() {
        if item.isPhysical && address.trimmingCharacters(in: .whitespaces).isEmpty {
            app.show(Tr("实物商品要填收货地址"))
            return
        }
        if total > balance {
            app.show(Tr("零钱不够（还差 ") + "¥" + moneyFmt(total - balance) + "）")
            return
        }
        Task {
            /* 设过支付密码才弹密码框（和转账一样） */
            let has = await API.shared.hasPayPassword()
            if has { showPay = true } else { _ = await submit(payPassword: "") }
        }
    }

    /// 真正下单，返回错误文字（nil = 成功）
    private func submit(payPassword: String) async -> String? {
        if busy { return nil }
        busy = true
        defer { busy = false }
        do {
            let r = try await API.shared.shopOrder(itemId: item.id, count: count,
                                                   address: address, payPassword: payPassword)
            let nb = r.balance ?? balance
            app.show(Tr("下单成功：") + (r.order?.name ?? item.name))
            DiagLog.shared.note("小店下单成功 \(item.name) ×\(count)，余额 ¥\(moneyFmt(nb))")
            onDone(nb)
            Task { app.me = try? await API.shared.me() }
            /* 支付密码那一层要自己先收起来（它收到 nil 就会关），
               这一层稍后再关 —— 两层 sheet 同时关在真机上容易卡住一张。 */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            return nil
        } catch {
            let msg = (error as? APIError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription ?? "下单失败"
            DiagLog.shared.note("小店下单失败：\(msg)")
            return msg
        }
    }
}

/// 支付密码那一步（六格 + 安全键盘，和转账 / 红包同一套手感）
struct ShopPaySheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let amount: Double
    let item: String
    /// 真正下单的动作，抛错 = 失败
    let pay: (String) async -> String?

    @State private var password = ""
    @State private var busy = false
    @State private var tip = ""
    @State private var shake: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text(item).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
            Text("¥\(moneyFmt(amount))")
                .font(pfMoney(32, .medium)).foregroundColor(C.label)
                .padding(.top, 6)

            PayDotField(count: password.count, shake: shake, busy: busy)
                .padding(.top, 16)
            if !tip.isEmpty {
                Text(tip).font(pf(13)).foregroundColor(C.red)
                    .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 10)
            }
            PayKeypadView(busy: busy) { tap($0) }
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .overlay { if busy { PayBusyOverlay() } }
        .background(C.pageBg.ignoresSafeArea())
        .presentationDetents([.height(452)])
    }

    private func tap(_ key: String) {
        if busy { return }
        if key == "⌫" {
            if !password.isEmpty { password.removeLast() }
            tip = ""
            return
        }
        guard !key.isEmpty, password.count < 6 else { return }
        password.append(key)
        tip = ""
        if password.count == 6 { run() }
    }

    private func run() {
        busy = true
        Task { @MainActor in
            let err = await pay(password)
            busy = false
            if let err = err {
                password = ""
                tip = err
                payShake($shake)
            } else {
                dismiss()
            }
        }
    }
}

/* ---------------------------------------------------------- 我的订单 */

struct ShopOrdersSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let orders: [API.ShopOrder]
    let balance: Double
    @State private var filter = 0        // 0 全部 / 1 待发货 / 2 已发货 / 3 已完成

    private let names = ["全部", "待发货", "已发货", "已完成"]

    /// 服务器给的 status 是「已下单 / 已发货 / 已完成 / 已取消」这种中文。
    /// 按状态分到那三档里（对不上的一律当「待发货」）。
    private func stage(_ s: String?) -> Int {
        let t = s ?? ""
        if t.contains("完成") || t.contains("收货") { return 3 }
        if t.contains("发货") || t.contains("途中") { return 2 }
        if t.contains("取消") { return 3 }
        return 1
    }

    private var shown: [API.ShopOrder] {
        filter == 0 ? orders : orders.filter { stage($0.status) == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的订单"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(0..<names.count, id: \.self) { i in
                            Button { filter = i } label: {
                                Text(Tr(names[i]))
                                    .font(pf(13.5))
                                    .foregroundColor(filter == i ? .white : C.label)
                                    .padding(.horizontal, 12).frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(filter == i ? C.green : C.cardBg))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)

                    if shown.isEmpty {
                        Text(Tr("还没有订单")).font(pf(14)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        GroupCard {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { i, o in
                                if i > 0 { HairLine(inset: 16) }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(o.name ?? Tr("订单")).font(pf(15.5)).foregroundColor(C.label)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("¥" + moneyFmt(o.price ?? 0))
                                            .font(pfMoney(15)).foregroundColor(C.label)
                                    }
                                    HStack(spacing: 8) {
                                        Text(o.status ?? Tr("已下单")).font(pf(12.5)).foregroundColor(C.subLabel)
                                        Spacer(minLength: 0)
                                        Text(TimeFmt.bill(o.at ?? "")).font(pf(12.5)).foregroundColor(C.subLabel)
                                    }
                                    if let a = o.address, !a.isEmpty {
                                        Text(Tr("地址：") + a).font(pf(12)).foregroundColor(C.subLabel)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                            }
                        }
                        Text(Tr("零钱余额 ") + "¥" + moneyFmt(balance))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.top, 2)
                    }
                        Spacer().frame(height: 30)
                }
                .padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        /* 2026-10-16：我的订单页同样补左滑返回 */
        .swipeBack { dismiss() }
    }
}
