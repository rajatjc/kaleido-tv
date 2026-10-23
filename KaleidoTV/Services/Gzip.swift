import Compression
import Foundation

/// Streams a .gz file to disk (programme guides are often served gzipped as plain files).
enum Gzip {
    private static let chunk = 1 << 20

    static func hasMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data([0x1f, 0x8b])
    }

    static func decompress(_ src: URL, to dst: URL, limit: Int) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else {
            throw FetchError("Couldn't write the unpacked file")
        }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        var pending = try input.read(upToCount: chunk) ?? Data()
        pending = Data(pending.dropFirst(try headerLength(Array(pending))))

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        // COMPRESSION_ZLIB is raw DEFLATE, which is exactly what sits inside a gzip wrapper.
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw FetchError("Couldn't unpack the download")
        }
        defer { compression_stream_destroy(stream) }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var total = 0
        var eof = false
        let empty: [UInt8] = [0]

        while true {
            if pending.isEmpty && !eof {
                pending = try input.read(upToCount: chunk) ?? Data()
                eof = pending.isEmpty
            }
            var consumed = 0
            var status = COMPRESSION_STATUS_OK
            let flags = eof ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let process: (UnsafePointer<UInt8>, Int) -> Void = { ptr, count in
                stream.pointee.src_ptr = ptr
                stream.pointee.src_size = count
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                status = compression_stream_process(stream, flags)
                consumed = count - stream.pointee.src_size
            }
            if pending.isEmpty {
                empty.withUnsafeBufferPointer { process($0.baseAddress!, 0) }
            } else {
                pending.withUnsafeBytes { process($0.bindMemory(to: UInt8.self).baseAddress!, $0.count) }
            }
            pending = Data(pending.dropFirst(consumed))
            let produced = chunk - stream.pointee.dst_size
            if produced > 0 {
                total += produced
                if total > limit { throw FetchError("Download is larger than allowed") }
                try output.write(contentsOf: Data(bytes: buffer, count: produced))
            }
            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_ERROR:
                throw FetchError("The download is damaged (bad gzip data)")
            default:
                if eof && produced == 0 && consumed == 0 {
                    throw FetchError("The download ended early (truncated gzip data)")
                }
            }
        }
    }

    /// Length of the gzip header (RFC 1952), including any optional name/comment/extra fields.
    private static func headerLength(_ b: [UInt8]) throws -> Int {
        guard b.count >= 10, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else {
            throw FetchError("Not a valid gzip file")
        }
        let flags = b[3]
        var p = 10
        func need(_ n: Int) throws { if p + n > b.count { throw FetchError("Not a valid gzip file") } }
        if flags & 0x04 != 0 {
            try need(2)
            p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8)
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {   // file name, comment: zero-terminated
            while true {
                try need(1)
                p += 1
                if b[p - 1] == 0 { break }
            }
        }
        if flags & 0x02 != 0 { p += 2 }
        try need(0)
        return p
    }
}
