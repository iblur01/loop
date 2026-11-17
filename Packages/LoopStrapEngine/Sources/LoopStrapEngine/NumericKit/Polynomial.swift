import Foundation

// MARK: - Polynomial

/// Swift port of `np.linalg.lstsq(X, y, rcond=None)` — ordinary least squares.
///
/// Solves the normal equations `(XᵗX)c = Xᵗy` by Gaussian elimination with **partial
/// pivoting** to find the coefficient vector `c` that minimises `‖Xc - y‖²`.
///
/// `X` is row-major: `X[i]` is observation `i`, `X[i][j]` is feature `j` of observation `i`.
/// The result has length `X[0].count` (number of parameters).
///
/// Numerical risk: Normal equations square the **condition number** of `X` — suitable for
/// `deg ≤ 2` fits on `n ≤ 100`, well-conditioned data as used throughout `units.py`.
/// Use QR decomposition (Householder) if precision issues arise on ill-scaled inputs.
///
/// - Parameters:
///   - X: Design matrix, row-major. `X.count` is the number of observations.
///   - y: Target vector. Must have the same length as `X`.
/// - Returns: Coefficient vector `c` of length `X[0].count`.
/// - Throws: `NumericError.emptyInput` if `X` or `y` is empty;
///           `NumericError.underdeterminedSystem` if `n < p` (fewer observations than params);
///           `NumericError.singularMatrix` if `XᵗX` is numerically singular (pivot < 1e-12).
public func leastSquares(X: [[Double]], y: [Double]) throws -> [Double] {
    guard !X.isEmpty && !y.isEmpty else { throw NumericError.emptyInput }
    guard X.count == y.count else { throw NumericError.underdeterminedSystem }
    let n = X.count
    let p = X[0].count
    guard n >= p else { throw NumericError.underdeterminedSystem }

    // Build p×p normal matrix A[j][k] = Σ X[i][j] * X[i][k]
    var A = [[Double]](repeating: [Double](repeating: 0.0, count: p), count: p)
    for j in 0..<p {
        for k in 0..<p {
            var sum = 0.0
            for i in 0..<n { sum += X[i][j] * X[i][k] }
            A[j][k] = sum
        }
    }

    // Build p-element right-hand side b[j] = Σ X[i][j] * y[i]
    var b = [Double](repeating: 0.0, count: p)
    for j in 0..<p {
        var sum = 0.0
        for i in 0..<n { sum += X[i][j] * y[i] }
        b[j] = sum
    }

    // Gaussian elimination with partial pivoting on the augmented matrix [A | b]
    for k in 0..<p {
        // Find the row in k..<p with the largest absolute value in column k
        var maxRow = k
        var maxVal = abs(A[k][k])
        for row in (k + 1)..<p {
            if abs(A[row][k]) > maxVal {
                maxVal = abs(A[row][k])
                maxRow = row
            }
        }
        // Swap rows k and maxRow in A and b
        if maxRow != k {
            A.swapAt(k, maxRow)
            b.swapAt(k, maxRow)
        }
        // Check for near-singular pivot
        guard abs(A[k][k]) >= 1e-12 else { throw NumericError.singularMatrix }
        // Eliminate below
        for row in (k + 1)..<p {
            let factor = A[row][k] / A[k][k]
            for col in k..<p {
                A[row][col] -= factor * A[k][col]
            }
            b[row] -= factor * b[k]
        }
    }

    // Back substitution to recover c
    var c = [Double](repeating: 0.0, count: p)
    for i in stride(from: p - 1, through: 0, by: -1) {
        var sum = b[i]
        for j in (i + 1)..<p { sum -= A[i][j] * c[j] }
        c[i] = sum / A[i][i]
    }
    return c
}

/// Swift port of `np.polyfit(x, y, deg)`.
///
/// Fits a degree-`deg` polynomial to points `(x[i], y[i])` by least squares.
///
/// Returns coefficients in **descending power order** `[c_deg, c_deg-1, ..., c_0]`,
/// matching `np.polyfit`'s convention. Builds a Vandermonde design matrix
/// `X[i] = [x[i]^deg, x[i]^(deg-1), ..., x[i]^0]` and delegates to `leastSquares`.
///
/// Used by `units.py` line 208-209 (degree 1, SpO2 window detrending) and by the
/// `leave_one_night_out` calibration fitter (also degree 1 in all test cases).
///
/// - Parameters:
///   - x: X-coordinates of the data points.
///   - y: Y-coordinates of the data points.
///   - deg: Degree of the polynomial to fit.
/// - Returns: Coefficients `[c_deg, ..., c_0]` in descending power order.
/// - Throws: `NumericError.emptyInput` if `x` or `y` is empty;
///           `NumericError.underdeterminedSystem` if `x.count < deg + 1`.
public func polyfit(_ x: [Double], _ y: [Double], deg: Int) throws -> [Double] {
    guard !x.isEmpty && !y.isEmpty else { throw NumericError.emptyInput }
    guard x.count >= deg + 1 else { throw NumericError.underdeterminedSystem }

    // Build Vandermonde design matrix X where X[i] = [x[i]^deg, x[i]^(deg-1), ..., x[i]^0]
    // Row-major: X has x.count rows and deg+1 columns.
    let designMatrix: [[Double]] = x.map { xi in
        (0...deg).reversed().map { power in
            pow(xi, Double(power))
        }
    }
    return try leastSquares(X: designMatrix, y: y)
}

/// Swift port of `np.polyval(coeffs, x)`.
///
/// Evaluates the polynomial with **descending-power** coefficients `[c_n, ..., c_1, c_0]`:
/// `c_n * x^n + c_{n-1} * x^{n-1} + ... + c_1 * x + c_0`.
///
/// Uses Horner's method for numerical stability and efficiency:
/// `((c_n * x + c_{n-1}) * x + ...) * x + c_0`.
///
/// Returns `0.0` for empty `coeffs`.
///
/// - Parameters:
///   - coeffs: Polynomial coefficients in descending power order.
///   - x: Point at which to evaluate the polynomial.
/// - Returns: The polynomial value at `x`.
public func polyval(_ coeffs: [Double], _ x: Double) -> Double {
    guard !coeffs.isEmpty else { return 0.0 }
    // Horner's method: start with coeffs[0], then accumulate
    return coeffs.dropFirst().reduce(coeffs[0]) { result, c in result * x + c }
}
