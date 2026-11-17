import Foundation

/// Small numeric helpers for the training module. All functions are total: they return
/// `nil` instead of dividing by zero or producing non-finite numbers, and are
/// independent of input order (sums are computed over sorted values).
enum TrainingMath {
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func sum(_ xs: [Double]) -> Double {
        xs.sorted().reduce(0, +)
    }

    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let m = sum(xs) / Double(xs.count)
        return m.isFinite ? m : nil
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Raw median absolute deviation around `center`.
    static func mad(_ xs: [Double], center: Double) -> Double? {
        median(xs.map { abs($0 - center) })
    }

    /// Population standard deviation (n >= 2).
    static func populationStdDev(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let v = sum(xs.map { ($0 - m) * ($0 - m) }) / Double(xs.count)
        return v >= 0 && v.isFinite ? v.squareRoot() : nil
    }

    /// Sample standard deviation (n >= 2).
    static func sampleStdDev(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let v = sum(xs.map { ($0 - m) * ($0 - m) }) / Double(xs.count - 1)
        return v >= 0 && v.isFinite ? v.squareRoot() : nil
    }

    /// Average ranks (1-based), ties share the mean rank.
    static func ranks(_ xs: [Double]) -> [Double] {
        let order = xs.indices.sorted { (i, j) in
            xs[i] != xs[j] ? xs[i] < xs[j] : i < j
        }
        var result = [Double](repeating: 0, count: xs.count)
        var start = 0
        while start < order.count {
            var end = start
            while end + 1 < order.count && xs[order[end + 1]] == xs[order[start]] { end += 1 }
            let avg = (Double(start) + Double(end)) / 2 + 1
            for k in start...end { result[order[k]] = avg }
            start = end + 1
        }
        return result
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2,
              let mx = mean(x), let my = mean(y) else { return nil }
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in x.indices {
            let dx = x[i] - mx
            let dy = y[i] - my
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        let r = sxy / (sxx * syy).squareRoot()
        guard r.isFinite else { return nil }
        return max(-1, min(1, r))
    }

    /// Spearman rank correlation; `nil` if a series is constant.
    static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count else { return nil }
        return pearson(ranks(x), ranks(y))
    }

    /// Approximate 95 % interval for a Spearman coefficient (Fisher transform with the
    /// Bonett-Wright standard error). `nil` below 10 pairs.
    static func spearmanInterval(rho: Double, n: Int) -> (low: Double, high: Double)? {
        guard n >= 10 else { return nil }
        let r = max(-0.999999, min(0.999999, rho))
        let z = 0.5 * log((1 + r) / (1 - r))
        let se = 1.06 / Double(n - 3).squareRoot()
        let lo = tanh(z - 1.96 * se)
        let hi = tanh(z + 1.96 * se)
        guard lo.isFinite, hi.isFinite else { return nil }
        return (lo, hi)
    }
}
