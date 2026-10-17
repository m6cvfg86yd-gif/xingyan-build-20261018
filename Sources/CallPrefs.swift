import Foundation

/* ============================================================
   通话偏好（2026-10-12 对齐微信补的三项）
     · 视频清晰度：标清 360p / 高清 720p / 超清 1080p（微信也是这三档）
     · 本地画面镜像：默认开（前置摄像头照镜子那样，微信默认也是镜像的）
     · 视频美颜：关 / 低 / 中 / 高（TRTC 自带美颜，人脸识别后磨皮提亮）
   都存在本机 UserDefaults；改完**当前这通电话立刻生效**（发一条通知给 TRTCBridge）。
   入口：我 → 设置 → 功能 → 音视频通话。
   ============================================================ */

enum CallPrefs {
    /// 0 标清 · 1 高清（默认）· 2 超清
    static var quality: Int {
        get { UserDefaults.standard.object(forKey: "callVideoQuality") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "callVideoQuality"); changed() }
    }
    static var qualityName: String {
        switch quality {
        case 0:  return "标清"
        case 2:  return "超清"
        default: return "高清"
        }
    }
    /// 本地预览镜像（默认开）
    static var mirror: Bool {
        get { UserDefaults.standard.object(forKey: "callMirror") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "callMirror"); changed() }
    }
    /// 美颜 0 关 · 1 低（默认）· 2 中 · 3 高
    static var beauty: Int {
        get { UserDefaults.standard.object(forKey: "callBeauty") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "callBeauty"); changed() }
    }
    static var beautyName: String {
        switch beauty {
        case 0:  return "关"
        case 2:  return "中"
        case 3:  return "高"
        default: return "低"
        }
    }

    /// 分辨率 / 帧率 / 码率（TRTC 推荐值）。resolution 用 TRTC 的原始枚举值：
    /// 640_360 = 108、1280_720 = 112、1920_1080 = 114（配 Portrait 就是竖屏 360x640 这种）。
    static func encoderParams() -> (resolution: Int, fps: Int32, bitrate: Int32) {
        switch quality {
        case 0:  return (108, 20, 600)
        case 2:  return (114, 24, 2600)
        default: return (112, 24, 1500)
        }
    }

    /// 改完通知一声（通话中立刻套上新的清晰度 / 镜像 / 美颜）
    private static func changed() {
        NotificationCenter.default.post(name: Notification.Name("chrisCallPrefsChanged"), object: nil)
    }
}
