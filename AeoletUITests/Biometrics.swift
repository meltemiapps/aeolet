import Darwin
import Foundation

/// Drives the Simulator's Face ID. These are the same Darwin notifications that
/// `xcrun simctl spawn <device> notifyutil -p ...` and the Simulator's Features > Face ID menu send.
/// The UI test runner lives inside the simulated device, so it can post them directly.
enum Biometrics {
    private typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
    private typealias RegisterCheck = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
    private typealias SetState = @convention(c) (Int32, UInt64) -> UInt32

    private static func symbol<T>(_ name: String, as type: T.Type) -> T {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { fatalError("Missing \(name)") }
        return unsafeBitCast(pointer, to: type)
    }

    private static func post(_ name: String) { _ = symbol("notify_post", as: Post.self)(name) }

    private static func setEnrolled(_ enrolled: Bool) {
        var token: Int32 = 0
        _ = symbol("notify_register_check", as: RegisterCheck.self)("com.apple.BiometricKit.enrollmentChanged", &token)
        _ = symbol("notify_set_state", as: SetState.self)(token, enrolled ? 1 : 0)
        post("com.apple.BiometricKit.enrollmentChanged")
    }

    static func enrol() { setEnrolled(true) }
    static func unenrol() { setEnrolled(false) }
    static func matchingFace() { post("com.apple.BiometricKit_Sim.pearl.match") }
    static func nonMatchingFace() { post("com.apple.BiometricKit_Sim.pearl.nomatch") }
}
