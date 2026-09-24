/// BLAKE3 hash (default 32-byte output, unkeyed), ported from the reference
/// implementation. CryptoKit has no BLAKE3, and the Grok CLI names long
/// session folders with it.
enum BLAKE3 {
    private static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    private static let permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
    private static let blockLength = 64
    private static let chunkLength = 1024
    private static let chunkStart: UInt32 = 1 << 0
    private static let chunkEnd: UInt32 = 1 << 1
    private static let parent: UInt32 = 1 << 2
    private static let root: UInt32 = 1 << 3

    /// Lowercase hex of the 32-byte digest.
    static func hexDigest(_ input: [UInt8]) -> String {
        hash(input).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    static func hash(_ input: [UInt8]) -> [UInt8] {
        // Every full chunk that more input follows is merged into the stack of
        // subtree chaining values, as in the reference incremental hasher.
        var stack: [[UInt32]] = []
        var chunkCounter: UInt64 = 0
        var offset = 0
        while input.count - offset > chunkLength {
            var cv = chunkOutput(input[offset..<offset + chunkLength], counter: chunkCounter)
                .chainingValue()
            chunkCounter += 1
            var total = chunkCounter
            while total & 1 == 0 {
                cv = parentOutput(left: stack.removeLast(), right: cv).chainingValue()
                total >>= 1
            }
            stack.append(cv)
            offset += chunkLength
        }
        var output = chunkOutput(input[offset...], counter: chunkCounter)
        while let left = stack.popLast() {
            output = parentOutput(left: left, right: output.chainingValue())
        }
        let words = compress(
            output.inputChainingValue, output.blockWords, counter: 0,
            blockLength: output.blockLength, flags: output.flags | root)
        return words.prefix(8).flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) }
        }
    }

    private struct Output {
        var inputChainingValue: [UInt32]
        var blockWords: [UInt32]
        var counter: UInt64
        var blockLength: UInt32
        var flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(
                compress(
                    inputChainingValue, blockWords, counter: counter,
                    blockLength: blockLength, flags: flags
                ).prefix(8))
        }
    }

    /// Compresses every block of one chunk but the last, and returns the last as an output.
    private static func chunkOutput(_ chunk: ArraySlice<UInt8>, counter: UInt64) -> Output {
        var cv = iv
        var start = chunk.startIndex
        var blocksCompressed = 0
        while chunk.endIndex - start > blockLength {
            let words = blockWords(chunk[start..<start + blockLength])
            let flags = blocksCompressed == 0 ? chunkStart : 0
            cv = Array(
                compress(
                    cv, words, counter: counter, blockLength: UInt32(blockLength), flags: flags
                ).prefix(8))
            blocksCompressed += 1
            start += blockLength
        }
        let last = chunk[start...]
        return Output(
            inputChainingValue: cv,
            blockWords: blockWords(last),
            counter: counter,
            blockLength: UInt32(last.count),
            flags: (blocksCompressed == 0 ? chunkStart : 0) | chunkEnd
        )
    }

    private static func parentOutput(left: [UInt32], right: [UInt32]) -> Output {
        Output(
            inputChainingValue: iv, blockWords: left + right, counter: 0,
            blockLength: UInt32(blockLength), flags: parent)
    }

    /// Little-endian words of one block, zero-padded to 64 bytes.
    private static func blockWords(_ block: ArraySlice<UInt8>) -> [UInt32] {
        var bytes = Array(block)
        bytes += [UInt8](repeating: 0, count: blockLength - bytes.count)
        return (0..<16).map { index in
            (0..<4).reduce(UInt32(0)) { word, byte in
                word | UInt32(bytes[index * 4 + byte]) << (8 * UInt32(byte))
            }
        }
    }

    private static func compress(
        _ cv: [UInt32], _ blockWords: [UInt32], counter: UInt64, blockLength: UInt32,
        flags: UInt32
    ) -> [UInt32] {
        var state =
            cv + Array(iv.prefix(4)) + [
                UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32),
                blockLength, flags,
            ]
        var message = blockWords
        for round in 0..<7 {
            mix(&state, 0, 4, 8, 12, message[0], message[1])
            mix(&state, 1, 5, 9, 13, message[2], message[3])
            mix(&state, 2, 6, 10, 14, message[4], message[5])
            mix(&state, 3, 7, 11, 15, message[6], message[7])
            mix(&state, 0, 5, 10, 15, message[8], message[9])
            mix(&state, 1, 6, 11, 12, message[10], message[11])
            mix(&state, 2, 7, 8, 13, message[12], message[13])
            mix(&state, 3, 4, 9, 14, message[14], message[15])
            if round < 6 {
                message = permutation.map { message[$0] }
            }
        }
        for index in 0..<8 {
            state[index] ^= state[index + 8]
            state[index + 8] ^= cv[index]
        }
        return state
    }

    private static func mix(
        _ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32
    ) {
        state[a] = state[a] &+ state[b] &+ x
        state[d] = rotateRight(state[d] ^ state[a], 16)
        state[c] = state[c] &+ state[d]
        state[b] = rotateRight(state[b] ^ state[c], 12)
        state[a] = state[a] &+ state[b] &+ y
        state[d] = rotateRight(state[d] ^ state[a], 8)
        state[c] = state[c] &+ state[d]
        state[b] = rotateRight(state[b] ^ state[c], 7)
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
