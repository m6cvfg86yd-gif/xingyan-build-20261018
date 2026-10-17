import SwiftUI

/* ============================================================
   拼多多商城的**后台**（放在 App「管理」页里）—— 2026-10-12 用户要求
   「拼多多商城后台给管理（可以上架的 / 换轮播图的）」「商城要的逻辑都要」。

   管理这一页能做的，和商城那一页一一对应：
     · 轮播图：换图 / 加一张 / 删一张（首屏最上面那块就是它）
     · 商品：上架（新增）/ 下架（关掉开关）/ 改价改名字改分类 / 删除
     · 商品图：可以用 emoji 顶，也可以从相册传一张真图（传上去存服务器）

   数据真源都在服务器 data/mall.json（GET /api/mall 读，POST /api/ops/mall 写），
   所以改完**用户那边重开商城就是新的**，不用重新出包。
   ============================================================ */

struct MallAdminSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var store = DDStore.shared

    @State private var editing: DDProduct? = nil
    @State private var adding = false
    @State private var editingAd: DDAd? = nil
    @State private var addingAd = false
    @State private var bannerPick = -1        // 正在换第几张轮播图（-1 = 没在换）
    @State private var bannerAdd = false
    @State private var busy = ""

    var body: some View {
        VStack(spacing: 10) {
            nameCard
            /* 开屏广告（2026-10-17 用户：「商城开屏3秒广告封面页可以跳过，给管理接上」） */
            splashCard
            /* 首页宫格（2026-10-17 用户：「百亿补贴那些位置都给管理换字换图标」） */
            channelCard
            bannerCard
            adsCard
            productCard
            /* 分销：开通 / 佣金比例 / 业绩榜（2026-10-16） */
            DistAdminCard().environmentObject(app)
            /* 2026-10-16：对着京东商家后台补的三块（发货 / 售后 / 发券）——
               都在 App 里操作，不用开电脑后台 */
            MallOpsSection()
        }
        .task { await store.refresh() }
        .sheet(item: $editing) { p in
            MallProductSheet(product: p).environmentObject(app)
        }
        .sheet(isPresented: $adding) {
            MallProductSheet(product: nil).environmentObject(app)
        }
        /* 换某一张轮播图：从相册选一张 → 上传 → 存到那一格 */
        .sheet(isPresented: Binding(get: { bannerPick >= 0 },
                                    set: { if !$0 { bannerPick = -1 } })) {
            PhotoPicker { img in
                let idx = bannerPick
                bannerPick = -1
                Task { await setBanner(idx, img) }
            }
        }
        .sheet(isPresented: $bannerAdd) {
            PhotoPicker { img in
                bannerAdd = false
                Task { await setBanner(-1, img) }
            }
        }
        .sheet(isPresented: $splashPick) {
            PhotoPicker { img in
                splashPick = false
                Task { await setSplashImage(img) }
            }
        }
        .sheet(item: $editingAd) { a in
            MallAdSheet(ad: a).environmentObject(app)
        }
        .sheet(isPresented: $addingAd) {
            MallAdSheet(ad: nil).environmentObject(app)
        }
    }

    /* ---------------- 商城名 / 标语 ---------------- */

    @State private var nameDraft = ""
    @State private var sloganDraft = ""
    @State private var nameLoaded = false

    private var nameCard: some View {
        VStack(spacing: 0) {
            row(Tr("商城名 / 标语（商城顶栏那两行）"), Tr("改完用户那边重开商城就是新的"))
            HairLine(inset: 16)
            TextField(Tr("商城名（比如 星言商城）"), text: $nameDraft)
                .font(pf(15))
                .padding(.horizontal, 14).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                .padding(.horizontal, 16).padding(.top, 10)
            TextField(Tr("标语（比如 拼着买 才便宜）"), text: $sloganDraft)
                .font(pf(15))
                .padding(.horizontal, 14).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                .padding(.horizontal, 16).padding(.top, 8)
            Button { Task { await saveName() } } label: {
                Text(Tr("保存商城名"))
                    .font(pf(15, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 21).fill(C.green))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 10).padding(.bottom, 12)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            if !nameLoaded { nameDraft = store.mallName; sloganDraft = store.mallSlogan; nameLoaded = true }
        }
        .onChange(of: store.mallName) { v in if !nameLoaded { nameDraft = v } }
    }

    private func saveName() async {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { app.show(Tr("商城名不能空")); return }
        await store.opsSetName(n, sloganDraft.trimmingCharacters(in: .whitespaces))
        busy = Tr("商城名已保存")
        app.show(Tr("商城名已保存"))
    }

    /* ---------------- 轮播图 ---------------- */

    private var bannerCard: some View {
        VStack(spacing: 0) {
            row(Tr("轮播图（商城首屏最上面那块）"), Tr("点「换图」从相册挑一张"))
            HairLine(inset: 16)
            if store.banners.isEmpty {
                hint(Tr("还没有轮播图，下面点「加一张轮播图」"))
            } else {
                ForEach(Array(store.banners.enumerated()), id: \.offset) { i, url in
                    if i > 0 { HairLine(inset: 16) }
                    HStack(spacing: 12) {
                        RemoteImage(path: url, icon: "photo")
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(Tr("第 ") + String(i + 1) + Tr(" 张"))
                            .font(pf(14)).foregroundColor(C.label)
                        Spacer(minLength: 0)
                        Button { bannerPick = i } label: { pill(Tr("换图"), C.green) }
                            .buttonStyle(.plain)
                        Button { Task { await removeBanner(i) } } label: {
                            pill(Tr("删除"), C.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).frame(height: 70)
                }
            }
            HairLine(inset: 16)
            Button { bannerAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 17)).foregroundColor(C.green)
                    Text(Tr("加一张轮播图")).font(pf(15.5)).foregroundColor(C.label)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /* ---------------- 商品 ---------------- */

    /* ---------------- 开屏广告（CHRIS_MALL_SPLASH_V1） ----------------
       2026-10-17 用户：「布置下商城开屏3秒广告封面页可以跳过，给管理接上，
       你不要放图」—— 所以这里只做**配置 + 上传**：
       封面由你从相册传，不传就完全不会弹开屏（代码里没有任何内置图）。 */
    @State private var splashDraft = DDSplash()
    @State private var splashLoaded = false
    @State private var splashPick = false

    private var splashCard: some View {
        VStack(spacing: 0) {
            row(Tr("开屏广告（打开商城时那 3 秒封面）"),
                Tr("不上传封面就不会弹；右上角「跳过」带倒计时，到点自动关"))
            HairLine(inset: 16)

            /* 开关 */
            HStack {
                Text(Tr("显示开屏广告")).font(pf(15.5)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { splashDraft.on ?? true },
                                         set: { splashDraft.on = $0 }))
                    .labelsHidden().tint(C.green)
            }
            .padding(.horizontal, 16).frame(height: 52)
            HairLine(inset: 16)

            /* 封面 */
            HStack(spacing: 12) {
                Group {
                    if let img = splashDraft.image, !img.isEmpty {
                        RemoteImage(path: img, icon: "photo")
                            .frame(width: 96, height: 54)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.fieldBg)
                            Text(Tr("还没传")).font(pf(12)).foregroundColor(C.subLabel)
                        }
                        .frame(width: 96, height: 54)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button { splashPick = true } label: { pill(Tr("上传封面"), C.green) }
                    .buttonStyle(.plain)
                if !((splashDraft.image ?? "").isEmpty) {
                    Button { splashDraft.image = ""; Task { await saveSplash() } } label: {
                        pill(Tr("清空"), C.red)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 72)
            HairLine(inset: 16)

            /* 显示几秒 */
            HStack(spacing: 8) {
                Text(Tr("显示时长")).font(pf(15)).foregroundColor(C.label)
                Spacer(minLength: 0)
                ForEach([3.0, 5.0, 10.0], id: \.self) { s in
                    Button { splashDraft.seconds = s } label: {
                        pill(String(Int(s)) + Tr(" 秒"),
                             (splashDraft.seconds ?? 3) == s ? C.green : C.subLabel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).frame(height: 48)
            HairLine(inset: 16)

            /* 跳过文案 */
            HStack(spacing: 10) {
                Text(Tr("跳过按钮文字")).font(pf(15)).foregroundColor(C.label)
                Spacer(minLength: 0)
                TextField(Tr("跳过"), text: Binding(get: { splashDraft.skipText ?? "跳过" },
                                                  set: { splashDraft.skipText = $0 }))
                    .font(pf(15)).multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            .padding(.horizontal, 16).frame(height: 48)
            HairLine(inset: 16)

            /* 点封面去哪 */
            HStack(spacing: 8) {
                Text(Tr("点封面")).font(pf(15)).foregroundColor(C.label)
                Spacer(minLength: 0)
                /* ⚠ 元组参数不要在闭包里拆成两个名字（Swift 5 不支持 tuple splat），
                   这里直接用 pair.0 / pair.1 取 */
                ForEach([("none", "不跳"), ("url", "网址"), ("product", "商品")], id: \.0) { pair in
                    Button { splashDraft.action = pair.0 } label: {
                        pill(Tr(pair.1), (splashDraft.action ?? "none") == pair.0 ? C.green : C.subLabel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).frame(height: 48)

            if (splashDraft.action ?? "none") == "product" {
                Menu {
                    ForEach(store.products) { p in
                        Button(p.title) { splashDraft.link = p.id }
                    }
                } label: {
                    HStack {
                        Text(store.products.first(where: { $0.id == (splashDraft.link ?? "") })?.title
                             ?? Tr("选一个商品"))
                            .font(pf(14.5)).foregroundColor(C.label).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11)).foregroundColor(C.subLabel)
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.fieldBg))
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
            } else if (splashDraft.action ?? "none") == "url" {
                TextField(Tr("https://…"), text: Binding(get: { splashDraft.link ?? "" },
                                                         set: { splashDraft.link = $0 }))
                    .font(pf(14.5)).autocapitalization(.none).disableAutocorrection(true)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.fieldBg))
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }

            Button { Task { await saveSplash() } } label: {
                Text(Tr("保存开屏广告"))
                    .font(pf(15, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 21).fill(C.green))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 6).padding(.bottom, 12)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            if !splashLoaded { splashDraft = store.splash; splashLoaded = true }
        }
        /* 商城配置从服务器拉回来之后（MallAdminSection 的 .task 里 refresh）同步一次，
           不然刚进后台可能显示的是空的 */
        .onChange(of: store.splash) { v in splashDraft = v }
    }

    private func saveSplash() async {
        busy = Tr("正在保存开屏广告…")
        await store.opsSetSplash(splashDraft)
        busy = Tr("开屏广告已保存")
        app.show(Tr("开屏广告已保存"))
    }

    /* ---------------- 首页宫格（百亿补贴那排，CHRIS_MALL_CHANNELS_V1） ----------------
       2026-10-17 用户：「百亿补贴那些位置都给管理换字换图标」。
       一格里能改：**文字、emoji（或 SF Symbol 图标名）、颜色、顺序、显示/隐藏**。 */
    @State private var channelDraft: [DDChannelItem] = []
    @State private var channelLoaded = false

    /// 宫格格子的"点它去哪"可选动作（前四个是频道页，后四个是功能页）
    static let channelActions: [(String, String)] = [
        ("subsidy", "百亿补贴（折扣专区）"),
        ("rank", "排行榜"),
        ("cheap", "9.9 包邮"),
        ("factory", "厂家直供"),
        ("orders", "我的订单"),
        ("cart", "购物车"),
        ("fav", "我的收藏"),
        ("views", "浏览足迹")
    ]
    static func channelActionName(_ key: String) -> String {
        (channelActions.first { $0.0 == key }?.1) ?? "百亿补贴（折扣专区）"
    }

    private var channelCard: some View {
        VStack(spacing: 0) {
            row(Tr("首页宫格（百亿补贴 / 排行榜 / 9.9包邮…）"),
                Tr("换字、换图标（emoji 优先）、换颜色、调顺序、隐藏；改完用户重开商城生效"))
            HairLine(inset: 16)

            if channelDraft.isEmpty {
                hint(Tr("还没加载出来，稍等一下"))
            }

            ForEach(channelDraft.indices, id: \.self) { i in
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(channelDraft[i].tintColor.opacity(0.12))
                                .frame(width: 34, height: 34)
                            if (channelDraft[i].emoji ?? "").isEmpty {
                                Image(systemName: channelDraft[i].symbol)
                                    .font(.system(size: 15)).foregroundColor(channelDraft[i].tintColor)
                            } else {
                                Text(channelDraft[i].emoji ?? "").font(.system(size: 17))
                            }
                        }
                        TextField(Tr("文字"), text: Binding(get: { channelDraft[i].title },
                                                          set: { channelDraft[i].title = $0 }))
                            .font(pf(15)).frame(maxWidth: 140)
                        TextField(Tr("emoji"), text: Binding(get: { channelDraft[i].emoji ?? "" },
                                                           set: { channelDraft[i].emoji = $0 }))
                            .font(pf(15)).frame(width: 64)
                        Spacer(minLength: 0)
                        Button {
                            channelDraft[i].on = !(channelDraft[i].on ?? true)
                        } label: {
                            pill((channelDraft[i].on ?? true) ? Tr("显示") : Tr("已隐藏"),
                                 (channelDraft[i].on ?? true) ? C.green : C.subLabel)
                        }
                        .buttonStyle(.plain)
                    }
                    /* 点这一格去哪（2026-10-17 用户：「百亿补贴那一些要可以添加删除」——
                       新加的那一格得能选目的地，不然点了不知道去哪） */
                    HStack(spacing: 8) {
                        Text(Tr("点它去哪")).font(pf(12)).foregroundColor(C.subLabel)
                        Menu {
                            ForEach(Self.channelActions, id: \.0) { a in
                                Button(Tr(a.1)) { channelDraft[i].action = a.0 }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(Tr(Self.channelActionName(channelDraft[i].action ?? "")))
                                    .font(pf(13)).foregroundColor(C.label)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9)).foregroundColor(C.subLabel)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Capsule().fill(C.fieldBg))
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Text(Tr("图标名")).font(pf(12)).foregroundColor(C.subLabel)
                        TextField("tag.fill", text: Binding(get: { channelDraft[i].icon ?? "" },
                                                           set: { channelDraft[i].icon = $0 }))
                            .font(pf(13))
                        Text(Tr("颜色")).font(pf(12)).foregroundColor(C.subLabel)
                        TextField("#E02F24", text: Binding(get: { channelDraft[i].tint ?? "" },
                                                          set: { channelDraft[i].tint = $0 }))
                            .font(pf(13)).frame(width: 86)
                        Text(Tr("顺序")).font(pf(12)).foregroundColor(C.subLabel)
                        TextField("1", value: Binding(get: { channelDraft[i].sort ?? 0 },
                                                     set: { channelDraft[i].sort = $0 }), format: .number)
                            .font(pf(13)).frame(width: 40)
                        Spacer(minLength: 0)
                        Button {
                            channelDraft.remove(at: i)
                        } label: { pill(Tr("删掉"), C.red) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if i < channelDraft.count - 1 { HairLine(inset: 16) }
            }

            HairLine(inset: 16)
            HStack(spacing: 10) {
                Button {
                    channelDraft.append(DDChannelItem(id: "ch" + String(Int(Date().timeIntervalSince1970) % 100000),
                                                      title: Tr("新入口"), icon: "tag.fill", emoji: "✨",
                                                      action: "subsidy", tint: nil, on: true,
                                                      sort: channelDraft.count + 1))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundColor(C.green)
                        Text(Tr("加一格")).font(pf(15)).foregroundColor(C.label)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button { Task { await saveChannels() } } label: {
                    Text(Tr("保存首页宫格"))
                        .font(pf(14.5, .medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 19).fill(C.green))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            if !channelLoaded {
                /* 后台没配过 → 拿内置八格当草稿（方便直接改）；
                   配过（哪怕被删空了）→ 就显示**真实的那份**（空的就是空的，别又冒出八格，
                   用户上次报的「删了不生效」就是这个）。 */
                channelDraft = store.channelsConfigured ? store.channels : DDChannelItem.builtin
                channelLoaded = true
            }
        }
        /* ⚠ 2026-10-17 用户：「首页9宫格那个我改了没生效」——
           原来这里挂着一句 `.onChange(of: store.channels) { v in if !v.isEmpty { channelDraft = v } }`：
           商城数据一刷新（进商城、下拉刷新都会走 refresh），就把用户**正在改的那份草稿**
           覆盖回服务器上的旧内容 —— 用户改完再点保存，存上去的其实是"没改过"的旧值。
           现在草稿只在进这一页时载一次，保存成功后由 saveChannels() 拿服务器那份回填。 */
    }

    private func saveChannels() async {
        busy = Tr("正在保存首页宫格…")
        let ok = await store.opsSetChannels(channelDraft)
        if ok {
            /* 存成功：用服务器回填的那份当草稿（万一后台对字段做了裁剪，界面和线上就一致了） */
            if store.channelsConfigured { channelDraft = store.channels }
            busy = Tr("首页宫格已保存")
            app.show(Tr("首页宫格已保存"))
        } else {
            /* 存失败别再说"已保存"——用户会以为生效了（2026-10-17「改了没生效」就是这么来的） */
            busy = Tr("保存失败")
            app.show(Tr("保存失败：后台没收到，检查网络后再点一次"))
        }
        /* 顺便把这笔写进后台日志：哪一版、几格、第一格叫什么、成没成，一看就知道 */
        CrashCatcher.note("首页宫格", "保存=\(ok ? "成功" : "失败")｜\(channelDraft.count) 格｜第一格=\(channelDraft.first?.title ?? "-")")
    }

    private func setSplashImage(_ img: UIImage) async {
        busy = Tr("正在上传封面…")
        guard let url = try? await API.shared.upload(image: img) else {
            busy = Tr("封面上传失败")
            return
        }
        splashDraft.image = url
        await store.opsSetSplash(splashDraft)
        busy = Tr("封面已保存")
        app.show(Tr("封面已保存"))
    }

    /* ---------------- 广告位（商城首页那些小广告） ----------------
       2026-10-16 用户：「把商城需要上传什么的、还缺的东西给 app 管理号接出来」——
       广告位以前只能在电脑后台改，现在管理号在手机上就能加 / 改 / 关 / 删。
       两种样子：`广告条`（楼层之间那一条）/ `插卡`（瀑布流里那一张卡）。 */
    private var adsCard: some View {
        VStack(spacing: 0) {
            row(Tr("广告位（商城里的京东式小广告）"),
                Tr("广告条插在楼层之间 · 插卡混在瀑布流里；开着 ") + String(store.ads.count)
                    + Tr(" 条 · 共 ") + String(store.allAds.count) + Tr(" 条"))
            if store.allAds.isEmpty {
                hint(Tr("还没有广告，下面点「加一条广告」"))
            } else {
                ForEach(store.allAds) { a in
                    HairLine(inset: 16)
                    HStack(spacing: 12) {
                        Text(a.emoji ?? "🛍")
                            .font(.system(size: 22))
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(hex: a.topColor).opacity(0.85)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.title).font(pf(14)).foregroundColor(C.label).lineLimit(2)
                            Text((a.isGrid ? Tr("插卡") : Tr("广告条")) + "　"
                                 + Tr("序号 ") + String(a.sort ?? 99) + "　" + adActionText(a))
                                .font(pf(11.5)).foregroundColor(C.subLabel).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 6) {
                            Toggle("", isOn: Binding(
                                get: { a.on ?? true },
                                set: { v in Task { await setAdOn(a, v) } }))
                                .labelsHidden().tint(C.green)
                                .scaleEffect(0.82)
                            Button { editingAd = a } label: { pill(Tr("编辑"), C.green) }
                                .buttonStyle(.plain)
                        }
                        Button { Task { await removeAd(a) } } label: { pill(Tr("删除"), C.red) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            HairLine(inset: 16)
            Button { addingAd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 17)).foregroundColor(C.green)
                    Text(Tr("加一条广告")).font(pf(15.5)).foregroundColor(C.label)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 这条广告点了会去哪儿（管理页上一眼能看清）
    private func adActionText(_ a: DDAd) -> String {
        switch a.action ?? "none" {
        case "vip":     return Tr("点开：会员中心")
        case "music":   return Tr("点开：听一听")
        case "subsidy": return Tr("点开：百亿补贴")
        default:        return (a.link ?? "").isEmpty ? Tr("不可点") : Tr("点开：链接")
        }
    }

    private func setAdOn(_ a: DDAd, _ on: Bool) async {
        var list = store.allAds
        guard let i = list.firstIndex(where: { $0.id == a.id }) else { return }
        list[i].on = on
        await store.opsAds(list)
        app.show(on ? Tr("广告已显示") : Tr("广告已隐藏"))
    }

    private func removeAd(_ a: DDAd) async {
        var list = store.allAds
        list.removeAll { $0.id == a.id }
        await store.opsAds(list)
        app.show(Tr("广告已删除"))
    }

    private var productCard: some View {
        VStack(spacing: 0) {
            row(Tr("商品（上架 / 下架 / 改价 / 删除）"),
                Tr("上架中的 ") + String(store.live.count) + Tr(" 件 · 共 ")
                    + String(store.products.count) + Tr(" 件"))
            if store.products.isEmpty {
                hint(Tr("还没有商品，下面点「上架一件新商品」"))
            } else {
                ForEach(Array(store.products.enumerated()), id: \.element.id) { i, p in
                    HairLine(inset: 16)
                    HStack(spacing: 12) {
                        DDThumb(em: p.em, size: 48, radius: 8, img: p.img)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(pf(14)).foregroundColor(C.label).lineLimit(2)
                            Text("¥" + moneyFmt(p.price) + "　" + Tr("单买 ¥") + moneyFmt(p.orig)
                                 + "　" + p.cate)
                                .font(pf(11.5)).foregroundColor(C.subLabel).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 6) {
                            Toggle("", isOn: Binding(
                                get: { p.live },
                                set: { v in Task { await setOn(p, v) } }))
                                .labelsHidden().tint(C.green)
                                .scaleEffect(0.82)
                            Button { editing = p } label: { pill(Tr("编辑"), C.green) }
                                .buttonStyle(.plain)
                        }
                        Button { Task { await remove(p) } } label: {
                            pill(Tr("删除"), C.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            HairLine(inset: 16)
            Button { adding = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 17)).foregroundColor(C.green)
                    Text(Tr("上架一件新商品")).font(pf(15.5)).foregroundColor(C.label)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !busy.isEmpty {
                Text(busy).font(pf(12)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /* ---------------- 小零件 ---------------- */

    private func row(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Text(sub).font(pf(12)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(pf(13)).foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(pf(12.5)).foregroundColor(c)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(c.opacity(0.12)))
    }

    /* ---------------- 动作 ---------------- */

    private func setBanner(_ idx: Int, _ img: UIImage) async {
        busy = Tr("正在上传图片…")
        guard let url = try? await API.shared.upload(image: img) else {
            busy = Tr("图片上传失败")
            return
        }
        var list = store.banners
        if idx >= 0 && idx < list.count { list[idx] = url } else { list.append(url) }
        await store.opsBanners(list)
        busy = Tr("轮播图已更新")
        app.show(Tr("轮播图已更新"))
    }

    private func removeBanner(_ idx: Int) async {
        var list = store.banners
        guard idx < list.count else { return }
        list.remove(at: idx)
        await store.opsBanners(list)
        busy = Tr("已删掉一张轮播图")
    }

    private func setOn(_ p: DDProduct, _ on: Bool) async {
        var np = p
        np.on = on
        await store.opsSave(np)
        busy = on ? (Tr("已上架：") + p.title) : (Tr("已下架：") + p.title)
    }

    private func remove(_ p: DDProduct) async {
        await store.opsRemove(p.id)
        busy = Tr("已删除：") + p.title
    }
}

/* ---------------------------------------------------------- 上架 / 编辑一件商品 */

struct MallProductSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    /// nil = 上架一件新的
    let product: DDProduct?

    @State private var em = "📦"
    @State private var img = ""
    @State private var title = ""
    @State private var price = ""
    @State private var orig = ""
    @State private var cate = ""
    @State private var shop = ""
    @State private var tags = ""
    @State private var grp = "2"
    @State private var sold = "0"
    @State private var on = true
    @State private var showPick = false
    @State private var saving = false

    private var editing: Bool { product != nil }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: editing ? Tr("编辑商品") : Tr("上架一件新商品"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        DDThumb(em: em, size: 72, radius: 10, img: img)
                        VStack(alignment: .leading, spacing: 8) {
                            Button { showPick = true } label: {
                                Text(Tr("从相册选一张商品图"))
                                    .font(pf(14)).foregroundColor(C.green)
                            }
                            .buttonStyle(.plain)
                            if !img.isEmpty {
                                Button { img = "" } label: {
                                    Text(Tr("去掉图片（用 emoji）"))
                                        .font(pf(13)).foregroundColor(C.red)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(Tr("不传图也行，用下面的 emoji 顶"))
                                .font(pf(11.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    fld(Tr("图标 emoji（比如 📦）"), $em)
                    fld(Tr("商品名字"), $title)
                    fld(Tr("拼单价（元）"), $price, num: true)
                    fld(Tr("单独购买价（元）"), $orig, num: true)
                    fld(Tr("分类（数码 / 服饰 / 食品…）"), $cate)
                    fld(Tr("店铺名"), $shop)
                    fld(Tr("标签，逗号隔开（百亿补贴,包邮）"), $tags)
                    fld(Tr("几人团（2~9）"), $grp, num: true)
                    fld(Tr("已拼人数（填 10万+ 这种也行）"), $sold)

                    HStack(spacing: 12) {
                        Text(Tr("上架")).font(pf(15.5)).foregroundColor(C.label)
                        Spacer(minLength: 0)
                        Toggle("", isOn: $on).labelsHidden().tint(C.green)
                    }
                    .padding(.horizontal, 16).frame(height: 56)
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Button { Task { await save() } } label: {
                Text(saving ? Tr("正在保存…") : (editing ? Tr("保存") : Tr("上架")))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23)
                        .fill(saving ? C.subLabel : Color(hex: 0xE02A0F)))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .padding(.top, 6)
            .padding(.bottom, max(10, L.safeBottom))
        }
        .background(C.pageBg.ignoresSafeArea())
        .ddLight()
        .onAppear { fill() }
        .sheet(isPresented: $showPick) {
            PhotoPicker { image in
                Task {
                    if let url = try? await API.shared.upload(image: image) {
                        img = url
                        app.show(Tr("图片已上传"))
                    }
                }
            }
        }
    }

    private func fld(_ ph: String, _ text: Binding<String>, num: Bool = false) -> some View {
        TextField(ph, text: text)
            .font(pf(15))
            .keyboardType(num ? .decimalPad : .default)
            .padding(.horizontal, 14).frame(height: 52)
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fill() {
        guard let p = product else { return }
        em = p.em
        img = p.img ?? ""
        title = p.title
        price = moneyFmt(p.price)
        orig = moneyFmt(p.orig)
        cate = p.cate
        shop = p.shop
        tags = p.tags.joined(separator: ",")
        grp = String(p.grp)
        sold = p.sold
        on = p.live
    }

    private func save() async {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { app.show(Tr("商品名字不能空")); return }
        saving = true
        let p = DDProduct(id: product?.id ?? "",
                          em: em.trimmingCharacters(in: .whitespaces).isEmpty ? "📦"
                              : em.trimmingCharacters(in: .whitespaces),
                          img: img.isEmpty ? nil : img,
                          title: name,
                          price: Double(price) ?? 0,
                          orig: Double(orig) ?? 0,
                          sold: sold.trimmingCharacters(in: .whitespaces).isEmpty ? "0" : sold,
                          grp: max(2, min(9, Int(grp) ?? 2)),
                          tags: tags.split(separator: ",")
                                  .map { $0.trimmingCharacters(in: .whitespaces) }
                                  .filter { !$0.isEmpty },
                          shop: shop.trimmingCharacters(in: .whitespaces),
                          cate: cate.trimmingCharacters(in: .whitespaces).isEmpty ? "其它"
                                : cate.trimmingCharacters(in: .whitespaces),
                          on: on)
        await store.opsSave(p)
        saving = false
        dismiss()
        app.show(editing ? Tr("商品已保存") : Tr("已上架"))
    }

    /* ============================================================ 广告位编辑
       一条广告 = 图标 emoji + 标题 + 副标题 + 按钮文字 + 样式（广告条 / 插卡）
                + 点开去哪儿（会员 / 听一听 / 百亿补贴 / 打开链接）+ 两个配色 + 序号 + 显示开关。 */
}

struct MallAdSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    /// nil = 加一条新的
    let ad: DDAd?

    @State private var emoji = "🛍"
    @State private var title = ""
    @State private var sub = ""
    @State private var cta = "去看看"
    @State private var kind = "strip"
    @State private var action = "none"
    @State private var link = ""
    @State private var top = ""
    @State private var bottom = ""
    @State private var sort = "10"
    @State private var on = true
    @State private var saving = false

    private var editing: Bool { ad != nil }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: editing ? Tr("编辑广告") : Tr("加一条广告"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    /* 预览：管理页改的样子，和商城里长的一样 */
                    HStack(spacing: 12) {
                        Text(emoji).font(.system(size: 26))
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(adTopColor))
                            .foregroundColor(.white)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title.isEmpty ? Tr("广告标题") : title)
                                .font(pf(14.5, .medium))
                                .foregroundColor(adTopColor)
                                .lineLimit(2)
                            Text(sub.isEmpty ? Tr("副标题（可空）") : sub)
                                .font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(cta.isEmpty ? Tr("去看看") : cta)
                            .font(pf(12, .medium)).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(adTopColor))
                    }
                    .padding(12)
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    /* 样式：广告条 / 插卡 */
                    HStack(spacing: 8) {
                        kindBtn(Tr("广告条"), "strip")
                        kindBtn(Tr("插卡"), "grid")
                        Spacer(minLength: 0)
                    }

                    fld(Tr("图标 emoji（比如 🛍 / 👑 / 🎧）"), $emoji)
                    fld(Tr("广告标题（必填）"), $title)
                    fld(Tr("副标题（可空）"), $sub)
                    fld(Tr("按钮文字（比如 去看看）"), $cta)

                    /* 点开去哪儿 */
                    VStack(spacing: 0) {
                        kindHint(Tr("点这条广告去哪儿"))
                        ForEach(adActions, id: \.0) { pair in
                            Button {
                                action = pair.0
                            } label: {
                                HStack(spacing: 10) {
                                    Text(pair.1).font(pf(15)).foregroundColor(C.label)
                                    Spacer(minLength: 0)
                                    if action == pair.0 {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(C.green)
                                    }
                                }
                                .padding(.horizontal, 16).frame(height: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            HairLine(inset: 16)
                        }
                    }
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if action == "none" {
                        fld(Tr("链接网址（https:// 开头，可空 = 不可点）"), $link)
                    }
                    fld(Tr("上面配色（十六进制，可空。比如 FF5F3A）"), $top)
                    fld(Tr("下面配色（十六进制，可空）"), $bottom)
                    fld(Tr("序号（越小越靠前）"), $sort, num: true)

                    HStack(spacing: 12) {
                        Text(Tr("显示这条广告")).font(pf(15.5)).foregroundColor(C.label)
                        Spacer(minLength: 0)
                        Toggle("", isOn: $on).labelsHidden().tint(C.green)
                    }
                    .padding(.horizontal, 16).frame(height: 56)
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Button { Task { await save() } } label: {
                Text(saving ? Tr("正在保存…") : (editing ? Tr("保存") : Tr("加上去")))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23)
                        .fill(saving ? C.subLabel : Color(hex: 0xE02A0F)))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .padding(.top, 6)
            .padding(.bottom, max(10, L.safeBottom))
        }
        .background(C.pageBg.ignoresSafeArea())
        .ddLight()
        .onAppear { fill() }
    }

    private var adTopColor: Color {
        let raw = top.isEmpty ? "FF5F3A" : top.replacingOccurrences(of: "#", with: "")
        return Color(hex: UInt32(raw, radix: 16) ?? 0xFF5F3A)
    }

    private var adActions: [(String, String)] {
        [("none", Tr("打开链接 / 不可点")),
         ("vip", Tr("会员中心")),
         ("music", Tr("听一听")),
         ("subsidy", Tr("百亿补贴"))]
    }

    private func kindBtn(_ t: String, _ v: String) -> some View {
        Button {
            kind = v
        } label: {
            Text(t)
                .font(pf(14, kind == v ? .semibold : .regular))
                .foregroundColor(kind == v ? .white : C.label)
                .padding(.horizontal, 16).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(kind == v ? C.green : C.cardBg))
        }
        .buttonStyle(.plain)
    }

    private func kindHint(_ t: String) -> some View {
        Text(t)
            .font(pf(12.5)).foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
    }

    private func fld(_ ph: String, _ text: Binding<String>, num: Bool = false) -> some View {
        TextField(ph, text: text)
            .font(pf(15))
            .keyboardType(num ? .decimalPad : .default)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 14).frame(height: 52)
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fill() {
        guard let a = ad else { return }
        emoji = a.emoji ?? "🛍"
        title = a.title
        sub = a.sub ?? ""
        cta = a.cta ?? "去看看"
        kind = a.kind ?? "strip"
        action = a.action ?? "none"
        link = a.link ?? ""
        top = a.top ?? ""
        bottom = a.bottom ?? ""
        sort = String(a.sort ?? 10)
        on = a.on ?? true
    }

    private func save() async {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { app.show(Tr("标题不能空")); return }
        saving = true
        var list = store.allAds
        let item = DDAd(id: ad?.id ?? ("ad" + String(Int(Date().timeIntervalSince1970))),
                        kind: kind,
                        emoji: emoji.trimmingCharacters(in: .whitespaces),
                        title: t,
                        sub: sub.trimmingCharacters(in: .whitespaces),
                        cta: cta.trimmingCharacters(in: .whitespaces),
                        top: top.trimmingCharacters(in: .whitespaces),
                        bottom: bottom.trimmingCharacters(in: .whitespaces),
                        action: action,
                        link: link.trimmingCharacters(in: .whitespaces),
                        on: on,
                        sort: Int(sort.trimmingCharacters(in: .whitespaces)) ?? 10)
        if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
        await store.opsAds(list)
        saving = false
        app.show(editing ? Tr("广告已保存") : Tr("广告已加上"))
        dismiss()
    }
}
