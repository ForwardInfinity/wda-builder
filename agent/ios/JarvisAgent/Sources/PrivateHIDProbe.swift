import CoreFoundation
import Darwin
import Foundation

struct PrivateHIDProbeResult {
    let symbols: Bool
    let client: Bool
    let dispatched: Bool
}

/// Bounded diagnostic only: one fixed public "1" key followed by Backspace.
/// No command can provide a usage page, usage, text, timing, or passcode.
enum PrivateHIDProbe {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias CreateKeyboardEvent = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, Bool, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias DispatchEvent = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void

    static func run(completion: @escaping (PrivateHIDProbeResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
                  let createClientSymbol = dlsym(handle, "IOHIDEventSystemClientCreateSimpleClient"),
                  let createEventSymbol = dlsym(handle, "IOHIDEventCreateKeyboardEvent"),
                  let dispatchSymbol = dlsym(handle, "IOHIDEventSystemClientDispatchEvent") else {
                completion(PrivateHIDProbeResult(symbols: false, client: false, dispatched: false))
                return
            }
            defer { dlclose(handle) }
            let createClient = unsafeBitCast(createClientSymbol, to: CreateClient.self)
            let createEvent = unsafeBitCast(createEventSymbol, to: CreateKeyboardEvent.self)
            let dispatchEvent = unsafeBitCast(dispatchSymbol, to: DispatchEvent.self)
            guard let client = createClient(kCFAllocatorDefault) else {
                completion(PrivateHIDProbeResult(symbols: true, client: false, dispatched: false))
                return
            }
            defer { Unmanaged<AnyObject>.fromOpaque(client).release() }

            func send(usage: UInt32, holdMicroseconds: useconds_t) -> Bool {
                guard let down = createEvent(kCFAllocatorDefault, 0, 0x07, usage, true, 0),
                      let up = createEvent(kCFAllocatorDefault, 0, 0x07, usage, false, 0) else {
                    return false
                }
                dispatchEvent(client, down)
                usleep(holdMicroseconds)
                dispatchEvent(client, up)
                Unmanaged<AnyObject>.fromOpaque(down).release()
                Unmanaged<AnyObject>.fromOpaque(up).release()
                return true
            }

            let digitSent = send(usage: 0x1E, holdMicroseconds: 150_000)
            usleep(1_500_000)
            let cleanupSent = send(usage: 0x2A, holdMicroseconds: 50_000)
            completion(PrivateHIDProbeResult(
                symbols: true,
                client: true,
                dispatched: digitSent && cleanupSent
            ))
        }
    }
}
