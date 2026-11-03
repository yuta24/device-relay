import Foundation

/// A `.xctestrun` in `Build/Products` and when it was last written.
struct XCTestRunFile: Equatable {
    var url: URL
    var modified: Date
}

/// Which `.xctestrun` `relay start` launches.
///
/// xcodebuild names the file after the SDK it built with (`RelayRunner_iphonesimulator27.2-arm64.xctestrun`),
/// but the build directory is per runner root, not per Xcode, so building with another Xcode
/// (`DEVELOPER_DIR`) adds a second file next to the first. The products those files point at
/// (`Debug-iphonesimulator`) are shared and are the last build's whatever the name says, so the file to use
/// is the one the last build wrote: every `build-for-testing` rewrites it, even with nothing to compile.
/// It is reused only if that build's SDK is this Xcode's; otherwise the runner is rebuilt.
enum XCTestRunSelection {
    enum Reuse: Equatable {
        /// The last build's file, for this SDK (or the SDK could not be told).
        case reuse(URL)
        /// Nothing was built yet.
        case none
        /// The last build used another SDK.
        case otherSDK(URL)
    }

    /// The SDK name `xcrun --sdk` takes, which is also how the file names begin after the scheme.
    static func platform(isSimulator: Bool) -> String {
        isSimulator ? "iphonesimulator" : "iphoneos"
    }

    /// The file the build just finished wrote. One written before the build started is left out, since the
    /// build rewrites its own; if none is newer (a coarse clock), the newest is still the last build's.
    static func built(_ files: [XCTestRunFile], since start: Date) -> URL? {
        // File systems store seconds or finer; allow for a clock that rounds down.
        let fresh = files.filter { $0.modified >= start.addingTimeInterval(-1) }
        return newest(fresh.isEmpty ? files : fresh)?.url
    }

    /// The file to reuse without building: the newest, if its SDK version is `sdkVersion`. A nil
    /// `sdkVersion` (xcrun could not tell) or a name relay cannot read reuses the newest, as before.
    static func reusable(_ files: [XCTestRunFile], platform: String, sdkVersion: String?) -> Reuse {
        guard let last = newest(files)?.url else { return .none }
        guard let sdkVersion, let built = self.sdkVersion(ofFileNamed: last.lastPathComponent, platform: platform) else {
            return .reuse(last)
        }
        return sameVersion(built, sdkVersion) ? .reuse(last) : .otherSDK(last)
    }

    /// Newest first; files written in the same instant go by name, the higher SDK version first.
    static func newest(_ files: [XCTestRunFile]) -> XCTestRunFile? {
        files.max { a, b in
            a.modified != b.modified ? a.modified < b.modified : a.url.lastPathComponent < b.url.lastPathComponent
        }
    }

    /// `27.2` from `RelayRunner_iphonesimulator27.2-arm64-x86_64.xctestrun` (`platform` `iphonesimulator`).
    /// Nil when the name has no `_<platform><version>` followed by `-` or the extension.
    static func sdkVersion(ofFileNamed name: String, platform: String) -> String? {
        guard name.hasSuffix(".xctestrun"),
              let range = name.range(of: "_\(platform)", options: .backwards) else { return nil }
        let rest = name[range.upperBound...].dropLast(".xctestrun".count)
        let version = String(rest.prefix { $0 != "-" })
        return isVersion(version) ? version : nil
    }

    /// Digits separated by dots, like `27`, `27.2`, or `26.0.1`.
    static func isVersion(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// `27.0` and `27` are the same version; `27.2` and `27.20` are not.
    static func sameVersion(_ a: String, _ b: String) -> Bool {
        func components(_ version: String) -> [Int] {
            var numbers = version.split(separator: ".").map { Int($0) ?? -1 }
            while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
            return numbers
        }
        return components(a) == components(b)
    }
}
