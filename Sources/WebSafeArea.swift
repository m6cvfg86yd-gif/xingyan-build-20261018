import Foundation
import UIKit

/* ============================================================
   给内置浏览器（游戏 / 小程序）注入「安全区」

   用户 2026-10-14：「全屏幕排版下字被遮住」——游戏页和小程序页是**铺满整屏**的
   （上一版因为「游戏不是全屏」特意忽略了安全区），但页面**自己的文字**顶在刘海/
   灵动岛底下就看不见了。

   微信小程序的做法是：小程序页面自己也吃安全区（页面内容从安全区下面开始，
   背景仍然是铺满的）。这里就照这个来 —— 注入两个 CSS 变量 + 给 body 一点内边距：

     · 画面/背景仍然铺满（我们没动 web view 的 frame，也没让它 ignoreSafeArea 失效）
     · 只有页面**内容**往下让开刘海、往上让开 home 指示条

   页面如果自己想用，也可以直接引用 `var(--chris-safe-top)` / `--chris-safe-bottom`。
   ============================================================ */

enum WebSafeArea {
    /// 注入的脚本（在 documentStart 执行，DOM 一就位就套上）
    static var js: String {
        let top = Int(max(0, L.safeTop).rounded())
        let bottom = Int(max(0, L.safeBottom).rounded())
        return """
        (function () {
          var st = \(top), sb = \(bottom);
          function apply() {
            var d = document.documentElement, b = document.body;
            if (d && d.style) {
              d.style.setProperty('--chris-safe-top', st + 'px');
              d.style.setProperty('--chris-safe-bottom', sb + 'px');
            }
            if (b && b.style) {
              if (st > 0) b.style.paddingTop = st + 'px';
              if (sb > 0) b.style.paddingBottom = sb + 'px';
              b.style.boxSizing = 'border-box';
            }
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', apply);
          } else {
            apply();
          }
          window.addEventListener('load', apply);
          window.chrisSafeArea = function () { apply(); return { top: st, bottom: sb }; };
        })();
        """
    }
}
