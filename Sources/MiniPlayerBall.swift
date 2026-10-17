import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

/* ============================================================
   迷你播放球（用户要求：「要有个小图标可以在后台挂起」）

   · 只要有一首在放（或暂停着），屏幕上就常驻一颗小圆球 —— 会话页、通讯录、
     视界、我、以及**聊天页**里都能看见（MainTab 和聊天页各挂一份，位置共用）
   · 点一下球 → 打开大播放页（和微信点开小条一个意思）
   · 右下角那颗小圆钮 → 直接 播放/暂停（不用点进大页面）
   · 左上角那个小 ✕ → 停掉，球收起来
   · 按住球拖到任意位置（松手自动吸到最近的一边），位置记在本机；
     **往下甩**（竖直方向甩出 96pt）＝ 关掉这个小球（不会自己弹回来）
   · 退到后台照样接着放（Info.plist 已声明 audio 后台模式），
     锁屏 / 控制中心 / 耳机线控上也能看到歌名并 播放·暂停·快进

   想调它（都不用重新出包，后台 ui.json 写键就行）：
     miniBallOn   0 = 不显示这颗球（默认 1 显示）
     miniBallSize 球的直径，默认 54
   ============================================================ */

struct MiniPlayerBall: View {
    @ObservedObject private var player = MusicPlayer.shared

    /* 挂起的样子（用户要求"按照微信的做"）：
       0 = 悬浮小球（老样子）  1 = **底部一条小播放条**（微信/苹果音乐那种，默认） */
    private var barStyle: Bool { UIConfig.num("miniBallStyle", 1) > 0 }

    /// 这颗球**只在屏幕上留一颗**：聊天那条全屏路径自己挂了一份，
    /// 外层这份在它弹出来时要先让位（不然两层都在画，过渡动画里会看到球在飘）。
    var hidden: Bool = false

    /* 位置存两样：**贴哪一边（0 左 / 1 右）+ 离屏幕底多少 pt**。
       不存比例 —— 按比例算的话，键盘弹起 / 切页 / 弹层推上来时 y 会跟着变
       （用户说的"小图标在乱跳"）。拖动跟手指 1:1 走、松手吸到最近一边，
       这就是用户说的「第一版最好」的那个手感。 */
    @AppStorage("miniBallSide") private var side: Int = 1                 // 0 左 / 1 右
    @AppStorage("miniBallBottom") private var storedBottom: Double = -1   // -1 = 还没拖过

    /// 这一次拖动的位移（松手归零，位置落进上面两个键里）
    @State private var dx: CGFloat = 0
    @State private var dy: CGFloat = 0
    @State private var dragging = false

    private var dia: CGFloat { max(42, min(76, UIConfig.num("miniBallSize", 54))) }
    private var on: Bool { UIConfig.num("miniBallOn", 1) > 0 }
    private var showing: Bool { on && !hidden && player.current != nil }

    var body: some View {
        if barStyle {
            miniBar
        } else {
            ballBody
        }
    }

    /// 微信那种底部小播放条：封面 + 歌名/歌手 + 播放暂停；点一下回大图，往下划收起来
    private var miniBar: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                MusicCover(path: player.current?.cover ?? "", size: 36, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "").font(pf(14)).foregroundColor(C.label).lineLimit(1)
                    Text(player.current?.artistText ?? "").font(pf(11.5)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button {
                    if let t = MusicPlayer.shared.current { MusicPlayer.shared.toggle(t) }
                } label: {
                    MusicPlayButton(playing: player.playing,
                                    loading: !player.loadingId.isEmpty && player.loadingId == (player.current?.id ?? ""),
                                    size: 32, tint: .white, bg: C.green)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background {
                ZStack {
                    Rectangle().fill(.bar)
                    C.cardBg.opacity(0.55)
                }
            }
            .overlay(alignment: .top) { HairLine() }
            .contentShape(Rectangle())
            .onTapGesture { openPlayer() }
            .gesture(DragGesture(minimumDistance: 10).onEnded { v in
                /* 往下划 = 收起来（和微信一样，不会自己弹回来） */
                if v.translation.height > 40 { MusicPlayer.shared.stop() }
            })
            .padding(.bottom, L.safeBottom + L.tabH)
        }
        .ignoresSafeArea()
        .opacity(showing ? 1 : 0)
        .allowsHitTesting(showing)
        .transition(.move(edge: .bottom))
        .animation(.easeOut(duration: 0.2), value: showing)
    }

    private var ballBody: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1), h = max(geo.size.height, 1)
            let pad = dia / 2 + 6
            let restX = side == 0 ? pad : w - pad
            let restY = h - (storedBottom < 0 ? defaultBottom : CGFloat(storedBottom))
            let cx = min(max(restX + dx, pad), w - pad)
            let cy = min(max(restY + dy, L.safeTop + pad), h - pad)

            /* ⚠ 手势必须挂在**球自己身上**，而且要在 .position **之前**：
               .position 会把这一层的框撑成整屏，挂在它后面的点击/拖动
               就等于"整个屏幕都是这颗球" —— 结果点哪儿都在点球、往下滑一下
               播放页就又被弹回来（用户反馈的「大卡片一直跳出来 / 滑下去又弹上来」）。
               顺序换成 手势 → position，命中区域就只剩那颗圆。 */
            ball
                .contentShape(Circle())
                /* 点球 = 回到大图（微信那套：往下划收成小球，点小球又回到播放页）。
                   用普通的 onTapGesture：**不能用 highPriorityGesture** ——
                   那样会把球里那两个小钮（播放/暂停、✕）的点击也抢走。
                   普通 tap 和拖动不冲突：手指一动就是拖动，原地抬起来就是点击。 */
                .onTapGesture { openPlayer() }
                /* ⚠ 必须 highPriorityGesture：普通 gesture 挂在列表/朋友圈这类
                   ScrollView 上面时，竖直拖动会被 ScrollView 的滚动手势抢走 ——
                   表现就是"拖一半球就不跟手了 / 又弹回原位"（用户说的拖起来很奇怪）。 */
                .highPriorityGesture(drag(w: w, h: h))
                .position(x: cx, y: cy)
        }
        .ignoresSafeArea()
        .opacity(showing ? 1 : 0)
        .allowsHitTesting(showing)
    }

    /// 没拖过的话：默认贴在右下角、底栏上面一点
    private var defaultBottom: CGFloat { dia / 2 + L.tabH + L.safeBottom + 10 }

    /* ------------------------------------------------------- 球本身 */

    private var ball: some View {
        ZStack {
            MusicCover(path: player.current?.cover ?? "", size: dia, radius: dia / 2)
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))

            /* 外圈那一道绿色进度 */
            Circle()
                .trim(from: 0, to: max(0.02, min(1, player.progress)))
                .stroke(C.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: dia - 1.5, height: dia - 1.5)

            /* 右下角：播放 / 暂停（在放的时候是一圈很淡的"呼吸"） */
            MusicPlayButton(playing: player.playing,
                            loading: !player.loadingId.isEmpty && player.loadingId == (player.current?.id ?? ""),
                            size: dia * 0.44)
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
                .offset(x: dia * 0.33, y: dia * 0.33)
                .onTapGesture {
                    guard let t = MusicPlayer.shared.current else { return }
                    MusicPlayer.shared.toggle(t)
                }

            /* 左上角：关掉（停播 + 收球） */
            ZStack {
                Circle().fill(Color.black.opacity(0.55))
                Image(systemName: "xmark")
                    .font(.system(size: dia * 0.17, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: dia * 0.36, height: dia * 0.36)
            .offset(x: -dia * 0.33, y: -dia * 0.33)
            .onTapGesture { MusicPlayer.shared.stop() }
        }
        .frame(width: dia, height: dia)
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        /* 拖着的时候放大一点（第一版有，用户说那个手感最好） */
        .scaleEffect(dragging ? 1.1 : 1)
        .animation(.easeOut(duration: 0.12), value: dragging)
    }

    private func openPlayer() {
        guard let t = MusicPlayer.shared.current else { return }
        MusicSheet.shared.open(t)
    }

    /* ------------------------------------------------------- 拖动 */

    private func drag(w: CGFloat, h: CGFloat) -> some Gesture {
        /* 起手距离别太大：以前 10pt 才动，球会"顿一下再跳" */
        DragGesture(minimumDistance: 5)
            .onChanged { v in
                dragging = true
                dx = v.translation.width
                dy = v.translation.height
            }
            .onEnded { v in
                let pad = dia / 2 + 6
                let restX = side == 0 ? pad : w - pad
                let restY = h - (storedBottom < 0 ? defaultBottom : CGFloat(storedBottom))

                /* 往下甩：关掉这颗球（用户说"卡片缩小后又自己弹回来"，
                   所以这里只有用户自己甩下来才收，别自动展开/自动弹回） */
                if v.translation.height > 96 && abs(v.translation.height) > abs(v.translation.width) * 1.4 {
                    dx = 0; dy = 0; dragging = false
                    MusicPlayer.shared.stop()
                    return
                }

                /* 松手：吸到最近的那一边（第一版那个手感），纵向记住离底多少 */
                let nx = min(max(restX + v.translation.width, pad), w - pad)
                let ny = min(max(restY + v.translation.height, L.safeTop + pad), h - pad)
                withAnimation(.easeOut(duration: 0.16)) {
                    side = nx < w / 2 ? 0 : 1
                    storedBottom = Double(min(max(h - ny, pad + 4), h - L.safeTop - pad))
                    dx = 0; dy = 0
                }
                dragging = false
            }
    }
}

/* ============================================================
   锁屏 / 控制中心 / 耳机线控（后台挂起时那颗"小图标"）

   MPNowPlayingInfoCenter 把在放的歌报给系统 —— 锁屏和控制中心就会显示
   歌名歌手 + 进度，还能拖进度；MPRemoteCommandCenter 收那几个按键。
   切歌、暂停、拖进度都同步过去（不改播放器本身的行为）。
   ============================================================ */

extension MusicPlayer {
    /// App 启动时挂一次（MusicPlayer.init 里调）
    func setupRemoteControls() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.removeTarget(nil)
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remotePlay() }
            return .success
        }

        c.pauseCommand.removeTarget(nil)
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.remotePause() }
            return .success
        }

        c.togglePlayPauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let t = self?.current else { return }
                self?.toggle(t)
            }
            return .success
        }

        /* 2026-10-15 用户：「灵动岛没法切换音乐」——
           以前这两颗是**写死关闭**的（isEnabled = false），所以锁屏 / 灵动岛 / 车机上
           点「上一首 / 下一首」是死的。现在接上：切歌走播放器那套 next()/prev()，
           有没有列表在 syncNowPlaying() 里再决定开不开（只有一首歌时系统会把按钮藏起来）。 */
        c.nextTrackCommand.removeTarget(nil)
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.removeTarget(nil)
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.prev() }
            return .success
        }

        /* 锁屏上拖进度条 */
        c.changePlaybackPositionCommand.removeTarget(nil)
        c.changePlaybackPositionCommand.addTarget { [weak self] ev in
            guard let e = ev as? MPChangePlaybackPositionCommandEvent, let self else { return .commandFailed }
            Task { @MainActor in
                /* 用 total（本地播放器和"边下边播"的流播放器都往里报时长） */
                guard self.total > 0 else { return }
                self.seek(e.positionTime / self.total)
                self.syncNowPlaying()
            }
            return .success
        }
    }

    private func remotePlay() {
        guard let t = current else { return }
        if let p = player {
            try? AVAudioSession.sharedInstance().setActive(true)
            p.play(); playing = true; startTimer(); syncNowPlaying()
        } else if let st = stream {
            /* 边下边播的那一首 */
            try? AVAudioSession.sharedInstance().setActive(true)
            st.play(); playing = true; startTimer(); syncNowPlaying()
        } else {
            play(t)
        }
    }

    private func remotePause() {
        player?.pause()
        stream?.pause()
        playing = false
        stopTimer()
        syncNowPlaying()
    }

    /// 把现在这首的 歌名/歌手/进度 报给系统（锁屏、控制中心、车机都用它）
    func syncNowPlaying() {
        /* 列表里只有一首（或没有列表）时，上一首/下一首没意义 → 关掉（系统会把它藏起来）；
           有列表才开，这样灵动岛 / 锁屏上点它就能切歌。 */
        let c = MPRemoteCommandCenter.shared()
        let canSkip = queue.count > 1
        if c.nextTrackCommand.isEnabled != canSkip { c.nextTrackCommand.isEnabled = canSkip }
        if c.previousTrackCommand.isEnabled != canSkip { c.previousTrackCommand.isEnabled = canSkip }
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = t.title
        info[MPMediaItemPropertyArtist] = t.artistText
        info[MPMediaItemPropertyPlaybackDuration] = total
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let art = MusicPlayer.cachedArtwork(t) {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    /// 封面本地缓存的图（没有就返回 nil —— 锁屏上就只是一行歌名）
    static func cachedArtwork(_ t: MusicTrack) -> UIImage? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let p = caches.appendingPathComponent("musiccover").appendingPathComponent("\(t.id)")
        return UIImage(contentsOfFile: p.path)
    }
}
