import Foundation

// MARK: - ArrayOps

/// Swift port of `numpy.diff(xs)`.
/// Returns an array of length `xs.count - 1` where `result[i] = xs[i+1] - xs[i]`.
/// Returns `[]` for arrays of length 0 or 1 — matches numpy.diff behavior.
/// Used by `sleep_features.py` and `hrv.py` via `np.diff`.
public func diff(_ xs: [Double]) -> [Double] {
    guard xs.count > 1 else { return [] }
    return zip(xs, xs.dropFirst()).map { $1 - $0 }
}

/// Swift port of `numpy.interp(xNew, xp, fp)`.
/// 1-D linear interpolation: for each x in `xNew`, finds position in `xp`
/// and linearly interpolates `fp`.
/// - Clamps at boundaries: x < xp[0] → fp[0]; x > xp.last → fp.last
/// - `xp` must be monotonically increasing (caller responsibility — matches numpy.interp contract).
/// - Returns `[]` if `xNew` or `xp` is empty.
/// Used by `sleep_features.py` via `np.interp`.
public func interp(_ xNew: [Double], _ xp: [Double], _ fp: [Double]) -> [Double] {
    guard !xNew.isEmpty && !xp.isEmpty else { return [] }
    guard xp.count == fp.count else {
        // Match numpy ValueError behavior — return empty rather than crashing.
        return []
    }
    return xNew.map { x -> Double in
        // Left clamp
        if x <= xp[0] { return fp[0] }
        // Right clamp
        if x >= xp[xp.count - 1] { return fp[fp.count - 1] }
        // Binary search for interval [xp[i], xp[i+1]) containing x
        var lo = 0
        var hi = xp.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if xp[mid] <= x {
                lo = mid
            } else {
                hi = mid
            }
        }
        // Linear interpolation in [xp[lo], xp[hi]]
        let t = (x - xp[lo]) / (xp[hi] - xp[lo])
        return fp[lo] + t * (fp[hi] - fp[lo])
    }
}

/// Swift port of `numpy.convolve(a, v, mode)`.
/// 1-D discrete linear convolution with kernel reversal (numpy semantics).
/// - `mode="full"` (default): output length = `a.count + v.count - 1`.
/// - `mode="valid"`: output length = `max(0, a.count - v.count + 1)`.
/// - Returns `[]` if either input is empty.
/// Empty input → empty output; matches numpy's defined contract (T-03-V5 disposition: accepted).
/// Used by `sleep_features.py` via `np.convolve(x, kernel, mode='valid')`.
public func convolve(_ a: [Double], _ v: [Double], mode: String = "full") -> [Double] {
    guard !a.isEmpty && !v.isEmpty else { return [] }
    let m = a.count
    let n = v.count

    if mode == "valid" {
        let outLen = max(0, m - n + 1)
        guard outLen > 0 else { return [] }
        var result = [Double](repeating: 0.0, count: outLen)
        for k in 0..<outLen {
            var sum = 0.0
            for j in 0..<n {
                sum += a[k + j] * v[n - 1 - j]
            }
            result[k] = sum
        }
        return result
    } else {
        // Full mode: output length = m + n - 1
        let outLen = m + n - 1
        var result = [Double](repeating: 0.0, count: outLen)
        for k in 0..<outLen {
            var sum = 0.0
            let iMin = max(0, k - n + 1)
            let iMax = min(k, m - 1)
            for i in iMin...iMax {
                sum += a[i] * v[k - i]
            }
            result[k] = sum
        }
        return result
    }
}
