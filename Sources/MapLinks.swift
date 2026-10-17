import Foundation
import CoreLocation
import UIKit

/* ============================================================
   高德 / 百度地图的跳转

   ⚠ 坐标必须先转：iOS 定位给的是 **WGS-84**，高德用 **GCJ-02**、百度用 **BD-09**。
   不转的话同一个点在高德/百度上会偏 500 米左右（用户看到的就是「位置发偏了」）。
   ============================================================ */

enum MapCoord {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    private static func outOfChina(lat: Double, lng: Double) -> Bool {
        if lng < 72.004 || lng > 137.8347 { return true }
        if lat < 0.8293 || lat > 55.8271 { return true }
        return false
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLng(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    /// WGS-84 → GCJ-02（高德、腾讯、微信自己用的那套）
    static func gcj02(lat: Double, lng: Double) -> (lat: Double, lng: Double) {
        if outOfChina(lat: lat, lng: lng) { return (lat, lng) }
        let dLat = transformLat(lng - 105.0, lat - 35.0)
        let dLng = transformLng(lng - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        let mgLat = lat + (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        let mgLng = lng + (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (mgLat, mgLng)
    }

    /// WGS-84 → BD-09（百度）
    static func bd09(lat: Double, lng: Double) -> (lat: Double, lng: Double) {
        let g = gcj02(lat: lat, lng: lng)
        let x = g.lng, y = g.lat
        let z = sqrt(x * x + y * y) + 0.00002 * sin(y * .pi * 3000.0 / 180.0)
        let theta = atan2(y, x) + 0.000003 * cos(x * .pi * 3000.0 / 180.0)
        return (z * sin(theta) + 0.006, z * cos(theta) + 0.0065)
    }
}

/// 用哪个地图打开
enum MapApp: String, CaseIterable, Identifiable {
    case amap = "高德地图"
    case baidu = "百度地图"
    case apple = "苹果地图"
    var id: String { rawValue }
}

enum MapLink {
    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    /// 装了 App 就跳 App，没装就开网页（高德/百度的网页版都不用 Key）
    static func open(_ app: MapApp, point: LocationPoint) {
        if let u = url(app, point: point, web: false), UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
            return
        }
        if let u = url(app, point: point, web: true) {
            UIApplication.shared.open(u)
        }
    }

    static func url(_ app: MapApp, point: LocationPoint, web: Bool) -> URL? {
        let name = point.title
        switch app {
        case .amap:
            let g = MapCoord.gcj02(lat: point.lat, lng: point.lng)
            if web {
                return URL(string: "https://uri.amap.com/marker?position=\(g.lng),\(g.lat)&name=\(enc(name))&coordinate=gaode&callnative=0")
            }
            return URL(string: "iosamap://path?sourceApplication=\(enc("星言"))&dlat=\(g.lat)&dlon=\(g.lng)&dname=\(enc(name))&dev=0&t=0")
        case .baidu:
            let b = MapCoord.bd09(lat: point.lat, lng: point.lng)
            if web {
                return URL(string: "https://api.map.baidu.com/marker?location=\(b.lat),\(b.lng)&title=\(enc(name))&content=\(enc(point.addr))&output=html&coord_type=bd09ll&src=webapp.luchat")
            }
            return URL(string: "baidumap://map/marker?location=\(b.lat),\(b.lng)&title=\(enc(name))&content=\(enc(point.addr))&coord_type=bd09ll&src=ios.luchat")
        case .apple:
            return URL(string: "http://maps.apple.com/?daddr=\(point.lat),\(point.lng)&q=\(enc(name))&dirflg=d")
        }
    }
}
