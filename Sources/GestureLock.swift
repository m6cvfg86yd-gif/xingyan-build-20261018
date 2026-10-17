import SwiftUI
import CryptoKit
import UIKit
import AudioToolbox

/* ============================================================
   手势密码（安全锁）—— 2026-10-12 重做的「高级版」

   和旧版做的事一样（开锁后进钱包要先画一遍手势、可以按面容解锁、手势只存在
   本机钥匙串、不上传），但整个手感重做了一版：
     · 九宫格：每个点是一颗有立体感的圆点（外环 + 内芯 + 高光），选中时内芯放大、
       外环点亮；连线是「宽光晕 + 细实线」两层圆头描边，画起来有质感；
     · 手指还没连到下一个点时，会从最后一个点拖一条「跟手虚线段」，和微信一样跟手；
     · 一碰一个点：轻震动（.light）；画错：错误震动 + 整盘变红 + 抖一下；成功：成功震动；
     · 顶部一块深色渐变卡：锁图标 + 标题 + 副标题 + 错误提示 + 「还可以试几次」；
     · 面容 / 指纹解锁做成一颗圆形玻璃按钮；
     · 设置页三步走（画一遍 → 再画一遍 → 完成）带步骤指示，成功时先给一个绿色对勾再退出。

   手势本身只存本机（SHA256(salt + 手势) 进钥匙串），服务器上没有任何影子。
   ============================================================ */

enum GestureStore {
    private static let key = "gestureLockPattern"
    private static let saltKey = "gestureLockSalt"

    static var enabled: Bool { Keychain.get(key) != nil }

    private static var salt: String {
        if let s = Keychain.get(saltKey), !s.isEmpty { return s }
        let s = UUID().uuidString
        Keychain.set(s, for: saltKey)
        return s
    }

    private static func hash(_ pattern: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "#" + pattern).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func set(_ pattern: String) { Keychain.set(hash(pattern), for: key) }
    static func verify(_ pattern: String) -> Bool { Keychain.get(key) == hash(pattern) }
    static func clear() { Keychain.remove(key) }
}

/* ---------------------------------------------------------- 九宫格 */

/// 九宫格：手指划过就把点连起来（返回的是 "0-4-8" 这种）
struct PatternPad: View {
    @Binding var picked: [Int]
    /// 画错了：整盘变红 + 抖一下
    var wrong: Bool = false
    /// 外框边长（默认 268）
    var box: CGFloat = 268
    var onEnd: () -> Void

    /// 手指现在在哪儿（画那段"还没连上点"的跟手线）
    @State private var finger: CGPoint? = nil
    /// 每碰一个新点震一下
    private let tapFb = UIImpactFeedbackGenerator(style: .light)

    private var dot: CGFloat { box * 0.232 }

    /// 主色：正常是青绿，画错是红
    private var ink1: Color { wrong ? Color(hexString: "#FF6B6B") : Color(hexString: "#34D399") }
    private var ink2: Color { wrong ? Color(hexString: "#E5484D") : Color(hexString: "#0EA5A0") }
    private var ring: Color { Color.dyn(0xC9CDD4, 0x41454D) }
    private var core: Color { Color.dyn(0xAEB3BB, 0x6B7078) }

    private func center(_ i: Int) -> CGPoint {
        let r = i / 3, c = i % 3
        let step = box / 3
        return CGPoint(x: step * (CGFloat(c) + 0.5), y: step * (CGFloat(r) + 0.5))
    }

    var body: some View {
        ZStack {
            /* 1) 连线的两层层：宽的一层当光晕，细的实线压在上面 */
            if picked.count > 1 {
                linePath
                    .stroke(ink1.opacity(0.22),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                linePath
                    .stroke(ink2,
                            style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                    .shadow(color: ink1.opacity(0.55), radius: 6)
            }
            /* 2) 手指到最后一个点那段跟手线（虚线、淡一点） */
            if let last = picked.last, let f = finger {
                Path { p in
                    p.move(to: center(last))
                    p.addLine(to: f)
                }
                .stroke(ink1.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [3, 5]))
            }

            /* 3) 九个点 */
            ForEach(0..<9, id: \.self) { i in
                dotView(i)
            }
        }
        .frame(width: box, height: box)
        .offset(x: wrong ? -7 : 0)
        .animation(wrong ? .default.repeatCount(3, autoreverses: true).speed(7) : .easeOut(duration: 0.18),
                   value: wrong)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    finger = v.location
                    for i in 0..<9 {
                        let p = center(i)
                        if hypot(p.x - v.location.x, p.y - v.location.y) < dot * 0.60,
                           !picked.contains(i) {
                            picked.append(i)
                            tapFb.impactOccurred()
                        }
                    }
                }
                .onEnded { _ in
                    finger = nil
                    onEnd()
                }
        )
        .onAppear { tapFb.prepare() }
    }

    private var linePath: Path {
        Path { path in
            guard let first = picked.first else { return }
            path.move(to: center(first))
            picked.dropFirst().forEach { path.addLine(to: center($0)) }
        }
    }

    /// 一颗点：外环 + 玻璃内芯 + 选中时放大 / 点亮 + 序号
    private func dotView(_ i: Int) -> some View {
        let p = center(i)
        let idx = picked.firstIndex(of: i)
        let on = idx != nil
        return ZStack {
            /* 外圈 */
            Circle()
                .fill(on ? AnyShapeStyle(LinearGradient(colors: [ink1.opacity(0.30), ink2.opacity(0.18)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                         : AnyShapeStyle(Color.clear))
                .overlay(
                    Circle().stroke(on ? ink2 : ring, lineWidth: on ? 2.4 : 1.4)
                )
                .frame(width: dot, height: dot)
                .shadow(color: on ? ink1.opacity(0.45) : Color.clear, radius: on ? 7 : 0)

            /* 内芯 */
            Circle()
                .fill(on
                      ? AnyShapeStyle(RadialGradient(colors: [ink1, ink2], center: .topLeading,
                                                     startRadius: 1, endRadius: dot * 0.36))
                      : AnyShapeStyle(core))
                .frame(width: on ? dot * 0.42 : dot * 0.24,
                       height: on ? dot * 0.42 : dot * 0.24)
                .shadow(color: on ? Color.white.opacity(0.35) : Color.clear, radius: 1.5, y: 0.6)

            /* 选中时显示这是第几个点（淡淡的，方便自己确认有没有画对） */
            if let n = idx {
                Text(String(n + 1))
                    .font(.system(size: dot * 0.19, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
            }
        }
        .frame(width: dot + 14, height: dot + 14)
        .position(p)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: on)
    }
}

/* ---------------------------------------------------------- 解锁（进钱包前画一遍） */

struct GestureLockView: View {
    var hint: String = "请输入手势密码"
    var onOk: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: [Int] = []
    @State private var error = ""
    @State private var checking = false
    /// 画错时让整盘变红 + 抖一下
    @State private var wrong = false
    /// 已经错了多少次（错了 5 次就让人先冷静一下）
    @State private var fails = 0
    /// 对了：整盘闪一下绿再放行
    @State private var okFlash = false

    private var triesLeft: Int { max(0, 5 - fails) }
    private var lockedOut: Bool { fails >= 5 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text(Tr("取消"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 6)

            /* 顶部那块：锁图标 + 标题 + 副标题 + 出错提示 */
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color.dyn(0xEAF7F1, 0x1E2A26), Color.dyn(0xDCEFE6, 0x18201E)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 54, height: 54)
                    Image(systemName: lockedOut ? "lock.slash.fill" : (okFlash ? "lock.open.fill" : "lock.fill"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(okFlash ? C.green : (lockedOut ? C.red : C.label))
                }
                .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)

                Text(hint)
                    .font(pf(19, .medium))
                    .foregroundColor(C.label)
                if !error.isEmpty {
                    Text(error).font(pf(13)).foregroundColor(C.red)
                } else {
                    Text(Tr("手势只存在这台手机上，不上传服务器"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                }
            }

            Spacer(minLength: 10)

            ZStack {
                /* 画对那一下从中间散开的一层绿光 */
                Circle()
                    .fill(C.green.opacity(okFlash ? 0.18 : 0))
                    .frame(width: okFlash ? 320 : 60, height: okFlash ? 320 : 60)
                    .blur(radius: 22)
                PatternPad(picked: $picked, wrong: wrong, box: 268) { check() }
            }

            Spacer(minLength: 8)

            if Biometrics.available {
                Button {
                    Task { await faceUnlock() }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(C.cardBg)
                                .frame(width: 48, height: 48)
                                .shadow(color: Color.black.opacity(0.10), radius: 7, y: 3)
                            Image(systemName: "faceid").font(.system(size: 20)).foregroundColor(C.green)
                        }
                        Text(Biometrics.label).font(pf(13)).foregroundColor(C.subLabel)
                    }
                }
                .buttonStyle(.plain)
            }

            if fails > 0 && !lockedOut {
                Text(Tr("还可以试 ") + String(triesLeft) + Tr(" 次"))
                    .font(pf(12.5)).foregroundColor(C.subLabel)
                    .padding(.top, 12)
            }
            if lockedOut {
                Text(Tr("试得太多次了：用「取消」退出去重进，或者用面容/指纹解锁"))
                    .font(pf(12.5)).foregroundColor(C.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30).padding(.top, 12)
            }

            Spacer(minLength: 22)
        }
        .background(C.pageBg.ignoresSafeArea())
    }

    private func check() {
        guard picked.count >= 4, !checking else {
            if picked.count > 0 && picked.count < 4 { error = "至少连 4 个点" }
            picked = []
            return
        }
        guard !lockedOut else {
            picked = []
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            return
        }
        checking = true
        let pattern = picked.map(String.init).joined(separator: "-")
        picked = []
        if GestureStore.verify(pattern) {
            /* 对了：成功震动 + 绿光闪一下再放行 */
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            error = ""
            okFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                okFlash = false
                checking = false
                onOk()
                dismiss()
            }
            return
        }
        /* 错了：错误震动 + 整盘变红抖一下 + 记一次 */
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        fails += 1
        error = fails >= 5 ? "手势错误（已试 5 次）" : "绘制错误，请重试"
        wrong = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { wrong = false }
        checking = false
    }

    private func faceUnlock() async {
        let r = await Biometrics.authenticate(reason: "验证身份，打开零钱")
        if r.ok {
            onOk()
            dismiss()
        } else if !r.message.isEmpty {
            error = r.message
        }
    }
}

/* ---------------------------------------------------------- 设置 / 修改 / 关闭 */

struct GestureSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState

    @State private var on = GestureStore.enabled
    @State private var step = 0            // 0 画第一次 · 1 再画一次确认
    @State private var first = ""
    @State private var picked: [Int] = []
    @State private var tip = "画一遍手势（至少连 4 个点）"
    @State private var error = ""
    @State private var verifyOld = false   // 改 / 关之前先验一次老的
    @State private var closing = false
    /// 画完了：先给一个绿色对勾，再退出
    @State private var finished = false

    /// 现在在整段流程的第几步（给顶上那个步骤条用）
    private var stageIndex: Int {
        if finished { return 2 }
        if verifyOld { return 0 }
        return first.isEmpty ? 0 : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("安全锁"), back: { dismiss() })

            if on && step == 0 && !verifyOld && !finished {
                ScrollView {
                    VStack(spacing: 0) {
                        statusCard
                        GroupCard {
                            row(Tr("修改手势密码")) { verifyOld = true; first = ""; step = 0; tip = "先画一遍现在的手势" }
                            HairLine(inset: 16)
                            row(Tr("关闭手势密码")) {
                                verifyOld = true; first = ""; step = 0
                                tip = "先画一遍现在的手势（验证后关闭）"
                                closing = true
                            }
                        }
                        .padding(.top, 10)
                        Spacer().frame(height: 30)
                    }
                    .padding(.top, 10)
                }
                .background(C.pageBg)
            } else if finished {
                VStack(spacing: 16) {
                    Spacer(minLength: 40)
                    ZStack {
                        Circle().fill(C.green.opacity(0.14)).frame(width: 92, height: 92)
                        Image(systemName: "checkmark")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundColor(C.green)
                    }
                    Text(Tr("手势密码已设置")).font(pf(18, .medium)).foregroundColor(C.label)
                    Text(Tr("进「钱包 / 零钱」要先画一遍这个手势")).font(pf(13)).foregroundColor(C.subLabel)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .background(C.pageBg)
            } else {
                VStack(spacing: 12) {
                    stepsBar
                    Spacer(minLength: 4)
                    Text(tip)
                        .font(pf(18, .medium))
                        .foregroundColor(C.label)
                    if !error.isEmpty {
                        Text(error).font(pf(13)).foregroundColor(C.red)
                    } else {
                        Text(Tr("至少连 4 个点，手势只存在这台手机上"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                    }
                    Spacer(minLength: 6)
                    PatternPad(picked: $picked, box: 268) { done() }
                    Button {
                        if GestureStore.enabled {
                            dismiss()
                        } else {
                            GestureStore.clear()
                            on = false
                            app.show(Tr("手势密码已关闭"))
                            dismiss()
                        }
                    } label: {
                        Text(Tr(GestureStore.enabled ? "取消" : "先不设置"))
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .padding(.top, 14)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.top, 18)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    /* 已经开着的时候那张状态卡 */
    private var statusCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.dyn(0xEAF7F1, 0x1E2A26), Color.dyn(0xDCEFE6, 0x18201E)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 54, height: 54)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(C.green)
            }
            Text(Tr("手势密码已开启")).font(pf(16, .medium)).foregroundColor(C.label)
            Text(Tr("进「钱包 / 零钱」要先画一遍；也可以按面容解锁")).font(pf(12.5)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    /* 三步条：① 画一遍 ② 再画一遍 ③ 完成 */
    private var stepsBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(i <= stageIndex ? C.green : C.subLabel.opacity(0.28))
                            .frame(width: 20, height: 20)
                        if i < stageIndex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text(String(i + 1))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(i == stageIndex ? .white : C.label)
                        }
                    }
                    Text(Tr(["画一遍", "再画一遍", "完成"][i]))
                        .font(pf(12.5))
                        .foregroundColor(i == stageIndex ? C.label : C.subLabel)
                    if i < 2 {
                        Rectangle()
                            .fill(i < stageIndex ? C.green : C.subLabel.opacity(0.28))
                            .frame(width: 18, height: 1.4)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private func row(_ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func done() {
        guard picked.count >= 4 else {
            if picked.count > 0 { error = "至少连 4 个点" }
            picked = []
            return
        }
        let pattern = picked.map(String.init).joined(separator: "-")
        picked = []
        error = ""

        /* 改 / 关之前：先验老的 */
        if verifyOld {
            guard GestureStore.verify(pattern) else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                error = "手势不对，再试一次"
                return
            }
            verifyOld = false
            if closing {
                closing = false
                GestureStore.clear()
                on = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                app.show(Tr("手势密码已关闭"))
                dismiss()
                return
            }
            tip = "画一遍新的手势"
            return
        }

        if first.isEmpty {
            first = pattern
            tip = "再画一遍确认"
            return
        }
        if first == pattern {
            GestureStore.set(pattern)
            on = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeOut(duration: 0.2)) { finished = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                app.show(Tr("手势密码设好了：进零钱要画一遍"))
                dismiss()
            }
        } else {
            first = ""
            tip = "两次不一样，重新画一遍"
            error = "两次手势不一样"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
