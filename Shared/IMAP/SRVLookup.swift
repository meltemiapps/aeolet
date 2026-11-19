import dnssd
import Foundation

/// DNS SRV lookups through the system resolver (RFC 2782).
enum SRVLookup {
    struct Record: Equatable {
        var priority: UInt16
        var weight: UInt16
        var port: Int
        var target: String
    }

    /// The record to use: lowest priority, then highest weight. A target of "." means the service is not offered.
    static func best(_ records: [Record]) -> Record? {
        records
            .filter { !$0.target.isEmpty && $0.target != "." && (1...65535).contains($0.port) }
            .sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.weight > $1.weight }
            .first
    }

    static func query(_ name: String, timeout: TimeInterval = 4) async -> [Record] {
        await withCheckedContinuation { continuation in
            Query(name: name, timeout: timeout) { continuation.resume(returning: $0) }.start()
        }
    }

    /// Parses SRV RDATA: priority, weight and port (16 bits each, network order), then the target as DNS labels.
    static func parse(_ data: [UInt8]) -> Record? {
        guard data.count >= 7 else { return nil }
        func u16(_ offset: Int) -> UInt16 { UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
        var labels: [String] = []
        var index = 6
        while index < data.count {
            let length = Int(data[index])
            if length == 0 { break }
            // Compression pointers are not used in RDATA returned by the resolver; treat one as malformed.
            guard length < 64, index + 1 + length <= data.count else { return nil }
            labels.append(String(decoding: data[(index + 1)...(index + length)], as: UTF8.self))
            index += 1 + length
        }
        return Record(priority: u16(0), weight: u16(2), port: Int(u16(4)), target: labels.isEmpty ? "." : labels.joined(separator: "."))
    }

    private final class Query {
        let name: String
        let timeout: TimeInterval
        let finish: ([Record]) -> Void
        let queue = DispatchQueue(label: "com.meltemiapps.aeolet.srv")
        var reference: DNSServiceRef?
        var records: [Record] = []
        var done = false
        var retained: Query?

        init(name: String, timeout: TimeInterval, finish: @escaping ([Record]) -> Void) {
            self.name = name
            self.timeout = timeout
            self.finish = finish
        }

        func start() {
            queue.async { [self] in
                retained = self
                let context = Unmanaged.passUnretained(self).toOpaque()
                let status = DNSServiceQueryRecord(&reference, 0, 0, name, UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN),
                                                   { _, flags, _, error, _, _, _, length, rdata, _, context in
                    guard let context else { return }
                    let query = Unmanaged<Query>.fromOpaque(context).takeUnretainedValue()
                    if error == kDNSServiceErr_NoError, let rdata, length > 0 {
                        let bytes = [UInt8](UnsafeRawBufferPointer(start: rdata, count: Int(length)))
                        if let record = SRVLookup.parse(bytes) { query.records.append(record) }
                    }
                    if error != kDNSServiceErr_NoError || flags & kDNSServiceFlagsMoreComing == 0 { query.complete() }
                }, context)
                guard status == kDNSServiceErr_NoError, let reference else { return complete() }
                DNSServiceSetDispatchQueue(reference, queue)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in complete() }
            }
        }

        /// Runs on the query's queue.
        func complete() {
            guard !done else { return }
            done = true
            if let reference { DNSServiceRefDeallocate(reference) }
            reference = nil
            finish(records)
            retained = nil
        }
    }
}
