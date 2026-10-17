import Foundation
import Speech

/* ============================================================
   把一段**录好的**语音文件转成文字（按住说话上滑「转文字」用）。
   用系统自带的语音识别：本地跑、不上传服务器、也不依赖第三方。
   微信的行为一样：转出来的文字进输入框，用户能改完再发。
   ============================================================ */

enum FileSpeech {
    /// 第一次用会弹系统的语音识别授权
    static func requestAuth() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    /// 等用户对「语音识别」授权，返回有没有允许。
    /// 按住说话上滑转文字以前是「先 requestAuth 再马上识别」——第一次用必然识别不出来
    /// （弹框还没点呢），用户看到的就是「没听清，再说一次」。
    static func authorize() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { st in
                cont.resume(returning: st == .authorized)
            }
        }
    }

    /// 识别一个音频文件；识别不出来（或超时）返回空串
    static func recognize(url: URL, timeout: TimeInterval = 12) async -> String {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer(),
              rec.isAvailable else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        /* 加上标点（iOS 16+）：转出来的中文带标点，看着才像"转好的文字" */
        if #available(iOS 16.0, *) { req.addsPunctuation = true }
        /* 有本机识别模型就用本机的：不上传、更快，也更私密 */
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            var finished = false
            let done: (String) -> Void = { text in
                if finished { return }
                finished = true
                cont.resume(returning: text)
            }
            rec.recognitionTask(with: req) { result, err in
                if let r = result, r.isFinal {
                    done(r.bestTranscription.formattedString)
                } else if err != nil {
                    done("")
                }
            }
            /* 兜底：识别器偶尔不回调（离线模型没下好、音频格式怪），别让界面一直等 */
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { done("") }
        }
    }
}
