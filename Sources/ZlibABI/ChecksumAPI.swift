// ChecksumAPI.swift - adler32, crc32, and combining them
//
// The pure part of the surface: no stream, no allocation, no state between calls. Which makes
// it the right thing to build first — every one of these is differential-testable against the
// reference on its own, with nothing else of this library working yet.
//
// The two `_combine` families are the only real work here. Both answer the same question: given
// a checksum over A and a checksum over B, what is the checksum over A followed by B, without
// having either. Adler-32 answers it with arithmetic, because its two sums are linear in the
// bytes. CRC-32 answers it in GF(2), because a CRC is a polynomial remainder and appending
// `len2` zero bytes to A is multiplying its polynomial by x^(8·len2).

import CZlib
import GZip
import Zlib

// -- Adler-32 -----------------------------------------------------------------

@c @implementation
public func adler32(_ adler: UInt, _ buf: UnsafePointer<UInt8>!, _ len: UInt32) -> UInt {
    adler32_z(adler, buf, Int(len))
}

@c @implementation
public func adler32_z(_ adler: UInt, _ buf: UnsafePointer<UInt8>!, _ len: Int) -> UInt {
    // A null buffer is how a caller asks for the initial value, and is not an error.
    guard let buf else { return 1 }

    var checksum = Adler32(resuming: UInt32(truncatingIfNeeded: adler))
    checksum.update(UnsafeBufferPointer(start: buf, count: len))

    return UInt(checksum.value)
}

@c @implementation
public func adler32_combine(_ adler1: UInt, _ adler2: UInt, _ len2: Int) -> UInt {
    combineAdler32(adler1, adler2, len2)
}

@c @implementation
public func adler32_combine64(_ adler1: UInt, _ adler2: UInt, _ len2: Int) -> UInt {
    combineAdler32(adler1, adler2, len2)
}

/// The two sums are each linear in the bytes, so the combined pair follows from the two pairs
/// and how far apart they are: every byte counted in `adler1`'s first sum was also counted
/// `len2` more times in the second sum than it would have been on its own.
private func combineAdler32(_ adler1: UInt, _ adler2: UInt, _ len2: Int) -> UInt {
    // The reference reports a negative length this way rather than by any error path, and
    // callers test for it, so the value is part of the contract.
    guard len2 >= 0 else { return ~UInt(0) & 0xFFFF_FFFF }

    let base: UInt = 65521
    let remainder = UInt(len2 % Int(base))

    var sum1 = adler1 & 0xFFFF
    var sum2 = (remainder &* sum1) % base

    sum1 += (adler2 & 0xFFFF) &+ base &- 1
    sum2 += ((adler1 >> 16) & 0xFFFF) &+ ((adler2 >> 16) & 0xFFFF) &+ base &- remainder

    if sum1 >= base { sum1 -= base }
    if sum1 >= base { sum1 -= base }
    if sum2 >= (base << 1) { sum2 -= (base << 1) }
    if sum2 >= base { sum2 -= base }

    return sum1 | (sum2 << 16)
}

// -- CRC-32 -------------------------------------------------------------------

@c @implementation
public func crc32(_ crc: UInt, _ buf: UnsafePointer<UInt8>!, _ len: UInt32) -> UInt {
    crc32_z(crc, buf, Int(len))
}

@c @implementation
public func crc32_z(_ crc: UInt, _ buf: UnsafePointer<UInt8>!, _ len: Int) -> UInt {
    guard let buf else { return 0 }

    var checksum = Crc32(resuming: UInt32(truncatingIfNeeded: crc))
    checksum.update(UnsafeBufferPointer(start: buf, count: len))

    return UInt(checksum.checksum)
}

@c @implementation
public func crc32_combine(_ crc1: UInt, _ crc2: UInt, _ len2: Int) -> UInt {
    crc32_combine_op(crc1, crc2, crc32_combine_gen64(len2))
}

@c @implementation
public func crc32_combine64(_ crc1: UInt, _ crc2: UInt, _ len2: Int) -> UInt {
    crc32_combine_op(crc1, crc2, crc32_combine_gen64(len2))
}

/// Precomputes the operator for a given length, so a caller combining many blocks of the same
/// size pays for the exponentiation once instead of per block.
@c @implementation
public func crc32_combine_gen(_ len2: Int) -> UInt {
    crc32_combine_gen64(len2)
}

@c @implementation
public func crc32_combine_gen64(_ len2: Int) -> UInt {
    // Appending `len2` bytes shifts the first CRC up by 8·len2 bits, and 8 is 2³ — so the
    // exponent starts three squarings in.
    xToTheNModP(len2, 3)
}

@c @implementation
public func crc32_combine_op(_ crc1: UInt, _ crc2: UInt, _ op: UInt) -> UInt {
    multiplyModP(op, crc1) ^ crc2
}

// -- polynomial arithmetic mod the CRC-32 polynomial ---------------------------
//
// Everything below works on polynomials over GF(2) packed into a word with the *most*
// significant bit as the x⁰ term — reflected, the same order the CRC itself is computed in, so
// that a CRC value and a polynomial here are the same bits meaning the same thing.

/// The reversed CRC-32 polynomial, as in `Crc32`.
private let polynomial: UInt = 0xEDB8_8320

/// Multiplies two polynomials modulo the CRC-32 polynomial.
///
/// Ordinary shift-and-add long multiplication, with the reduction folded into the shift: `b`
/// times x is `b` shifted down one, and exclusive-ored with the polynomial when the term that
/// falls off is nonzero.
private func multiplyModP(_ a: UInt, _ b: UInt) -> UInt {
    var product: UInt = 0
    var b = b
    var mask: UInt = 1 << 31

    while true {
        if a & mask != 0 {
            product ^= b

            if a & (mask - 1) == 0 { break }
        }

        mask >>= 1
        b = b & 1 != 0 ? (b >> 1) ^ polynomial : b >> 1
    }

    return product
}

/// x raised to the (n · 2^k), modulo the polynomial.
///
/// Exponentiation by squaring, with the squares precomputed: bit i of `n` contributes the
/// (k+i)-th entry of the table, which is x^(2^(k+i)).
private func xToTheNModP(_ n: Int, _ k: UInt) -> UInt {
    var power: UInt = 1 << 31 // x⁰, the multiplicative identity in this representation.
    var n = n
    var k = k

    while n != 0 {
        if n & 1 != 0 {
            power = multiplyModP(squaresOfX[Int(k & 31)], power)
        }

        n >>= 1
        k += 1
    }

    return power
}

/// x^(2^n) for n in 0...31, each the square of the one before.
private let squaresOfX: [UInt] = {
    var table = [UInt](repeating: 0, count: 32)

    table[0] = 1 << 30 // x¹

    for index in 1 ..< 32 {
        table[index] = multiplyModP(table[index - 1], table[index - 1])
    }

    return table
}()
