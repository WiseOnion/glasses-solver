# MATH 131 Calculus I (Honors), NC A&T, Fall 2026

What the app needs to know about the current unit. When this file is complete, it replaces the
"WHAT THIS COURSE TESTS" section of `ClaudeClient.system`. The old section covered Test 2 material:
the limit definition, chain rule, log rules, implicit differentiation and related rates.

**Test 3 covers Modules 7 and 8.** (Canvas, Practice Test 3 page: "know the definitions, theorems and
how to apply them.")

| Module | Topics |
|---|---|
| 7.1 | Absolute max/min on a closed interval, local max/min on an open interval |
| 7.2 | Increasing/decreasing intervals, First Derivative Test |
| 7.3 | Concavity, points of inflection, Second Derivative Test |
| 7.4 | Graphing functions |
| 8.1 | Optimization: primary (objective) equation and secondary (constraint) equation |
| 8.2 | Linear approximation, differentials |
| 8.3 | L'Hôpital's Rule: 0/0, ∞/∞, then 1^∞, 0⁰, ∞⁰ (by logs) and ∞ − ∞ (by one fraction) |
| 8.4 | Rolle's Theorem, Mean Value Theorem and its applications |

---

## 7.2 Increasing and decreasing functions, First Derivative Test

Sources: the instructor's own 7.2 lecture (Panopto), and Mr. Tarrou's YouTube video linked from
the Week 10 module. **Where they differ, the instructor wins.** Every example answer was checked by hand.

### The instructor's rules (these cost points)
- **Proof, not a picture.** "If you graph something but you can't prove it, you get zero points." A
  calculator graph only checks the answer; the work must show the steps below.
- **State the domain first** (set notation and interval notation), and never test a value outside it.
  For t²√(t + 6): t ≥ −6, so [−6, ∞).
- **Critical numbers must be interior points of the domain.** A value that makes f′ undefined at a domain
  endpoint (t = −6 above) or outside the domain (±3 for w²/(w² − 9)) is **not** a critical number.
  Discontinuities still split the number line into test intervals.
- **Critical number** = the x value. **Critical point** = the ordered pair (c, f(c)). Give the points.
- **Show each test value in f′**, with its sign: "h′(−1) = −24 < 0". The value itself matters less than
  the sign, but it has to be shown.
- **The conclusion is about f, not f′:** "h is decreasing on (−∞, 0)", never "h′ is decreasing".
- **Open intervals with parentheses only**, never brackets, for increasing/decreasing.
- **The First Derivative Test is only for local extrema.** Don't cite it for increasing/decreasing (that
  comes from the sign test). Cite it for extrema: "By the First Derivative Test, f has a local maximum at
  x = −3", then the point.
- The instructor says **local** max/min (the video says "relative"). Local extrema are interior points only;
  absolute extrema can be at endpoints.
- **Fractions need a division line.** When combining terms over a common denominator, write a real
  fraction bar, not a slash.
- A square root is rewritten as a ½ power before the product or chain rule (√(t + 6) = (t + 6)^½), and
  the product rule starts with u, v, u′, v′ written out, the same as the rest of the course.

### The instructor's worked examples
1. **h(x) = x⁴ − 4x³ + 4x²**, domain ℝ.
   - h′(x) = 4x³ − 12x² + 8x = 4x(x − 2)(x − 1). Never undefined (polynomial). Critical numbers 0, 1, 2.
   - Intervals (−∞, 0), (0, 1), (1, 2), (2, ∞), tested at −1, 0.5, 1.5, 3:
     h′(−1) = −24 < 0, h′(0.5) = 1.5 > 0, h′(1.5) = −1.5 < 0, h′(3) = 24 > 0.
   - h is increasing on (0, 1) and (2, ∞), decreasing on (−∞, 0) and (1, 2).
2. **h(t) = t²√(t + 6)**, domain [−6, ∞).
   - u = t², v = (t + 6)^½, u′ = 2t, v′ = ½(t + 6)^(−½).
   - h′(t) = 2t√(t + 6) + t² / (2√(t + 6)). Common denominator 2√(t + 6):
     h′(t) = [4t(t + 6) + t²] / (2√(t + 6)) = (5t² + 24t) / (2√(t + 6)).
   - h′ = 0: t(5t + 24) = 0, so t = 0 and t = −24/5 ≈ −4.8, both inside (−6, ∞). h′ undefined at
     t = −6, the endpoint, so not a critical number.
   - Intervals (−6, −24/5), (−24/5, 0), (0, ∞), tested at −5, −1, 1: h′(−5) = 2.5 > 0, then < 0, then > 0.
   - h is increasing on (−6, −24/5) and (0, ∞), decreasing on (−24/5, 0). Local max at t = −24/5
     (h = (576/25)√(6/5) ≈ 25.24), local min at (0, 0).
3. **f(x) = 2x³ + 12x² + 18x**, domain ℝ.
   - f′(x) = 6x² + 24x + 18 = 6(x + 3)(x + 1). Critical numbers −3, −1; critical points (−3, 0), (−1, −8).
   - Tested at −4, −2, 0: +, −, +. Increasing on (−∞, −3) and (−1, ∞), decreasing on (−3, −1).
   - By the First Derivative Test, f has a local maximum at x = −3, point (−3, 0), and a local minimum at
     x = −1, point (−1, −8).
4. **g(w) = w² / (w² − 9)**, domain all w ≠ ±3.
   - u = w², v = w² − 9, u′ = 2w, v′ = 2w. g′(w) = [2w(w² − 9) − w²(2w)] / (w² − 9)², factor 2w:
     2w(w² − 9 − w²) / (w² − 9)² = −18w / (w² − 9)². (w² − 9 doesn't cancel: it isn't a factor on top.)
   - g′ = 0 at w = 0. g′ undefined at ±3, which aren't in the domain, so the only critical number is 0.
   - Intervals (−∞, −3), (−3, 0), (0, 3), (3, ∞), tested at −4, −1, 1, 4: +, +, −, −.
   - By the First Derivative Test, g has a local maximum at w = 0, point (0, 0). Even if the sign changed
     at ±3 there'd be no extremum there, since they aren't in the domain.

### Definitions
- **Increasing on an interval:** for any x₁ < x₂ in it, f(x₁) < f(x₂). The graph rises to the right.
- **Decreasing on an interval:** for any x₁ < x₂ in it, f(x₁) > f(x₂). The graph falls to the right.
- **Test:** f continuous on [a, b] and differentiable on (a, b). If f′(x) > 0 on (a, b), f is increasing;
  f′(x) < 0, decreasing; f′(x) = 0, constant.
- **Strictly monotonic:** only increasing or only decreasing on the whole interval (a cubic can level
  off and keep rising).

### Steps for the intervals
1. Find f′(x).
2. **Critical numbers:** solve f′(x) = 0, and find where f′(x) is undefined (a denominator equal to 0,
   tangent at odd multiples of π/2).
3. Also find where **f itself** is undefined. Those x values still split the number line into test
   intervals, but they can't be a max or min.
4. Test intervals: split the domain (or the interval given, such as [0, 2π]) at those values, from
   left to right.
5. Put one test value from each interval into **f′** (not f). A positive result means increasing on that
   interval, a negative one means decreasing. Only the sign matters.

### First Derivative Test
c is a critical number of f, and f is continuous on an open interval containing c (differentiable
except possibly at c).
- f′ changes **− to +** at c: **relative minimum** at (c, f(c)).
- f′ changes **+ to −** at c: **relative maximum** at (c, f(c)).
- f′ **doesn't change sign**: neither (the graph levels off and keeps going).
- The y value comes from putting c into the **original f**, not f′.
- A max or min can be at a sharp bend (f′ undefined, f continuous, like |x|).
- **Never** at a discontinuity: a vertical asymptote or a hole. A hole is approached but never
  reached, so there's no highest or lowest point there.

### Worked examples (from the YouTube video)
1. **f(x) = (1/3)x³ − (1/2)x² − 6x + 4**
   - f′(x) = x² − x − 6 = (x − 3)(x + 2). Critical numbers −2 and 3. f′ is never undefined (polynomial).
   - (−∞, −2): test −3, f′ = 6 > 0, increasing. (−2, 3): test 0, f′ = −6 < 0, decreasing.
     (3, ∞): test 4, f′ = 6 > 0, increasing.
   - Relative max at (−2, 34/3), about (−2, 11.3). Relative min at (3, −19/2) = (3, −9.5).
2. **y = 2x² / (x² − 4)**
   - Quotient rule: y′ = [(x² − 4)(4x) − (2x²)(2x)] / (x² − 4)² = (4x³ − 16x − 4x³) / (x² − 4)²
     = −16x / (x² − 4)².
   - y′ = 0 at x = 0. y′ undefined at x = ±2, but **y is undefined there too** (vertical
     asymptotes), so they set up intervals but are not extrema.
   - Intervals (−∞, −2), (−2, 0), (0, 2), (2, ∞): +, +, −, −. Increasing on (−∞, −2) and (−2, 0);
     decreasing on (0, 2) and (2, ∞).
   - Relative max at (0, 0). Horizontal asymptote y = 2 (equal degrees, leading coefficients 2/1).
3. **y = x − 5 cos x on [0, 2π]**
   - y′ = 1 + 5 sin x. Set to 0: sin x = −1/5. The calculator gives sin⁻¹(−1/5) ≈ −0.2014, which is
     **outside [0, 2π]**. Sine is negative in quadrants III and IV, so use the reference angle 0.2014:
     x = π + 0.2014 ≈ 3.343 and x = 2π − 0.2014 ≈ 6.082. Calculator in radians.
   - [0, 3.343): +, increasing. (3.343, 6.082): −, decreasing. (6.082, 2π]: +, increasing.
   - Relative max ≈ (3.343, 8.24). Relative min ≈ (6.082, 1.18).
4. **f(x) = x⁴ − 2x² + 1** (second Week 10 YouTube link)
   - f′(x) = 4x³ − 4x = 4x(x + 1)(x − 1). Critical numbers −1, 0, 1.
   - Tested at −2, −½, ½, 2: f′(−2) = −24 < 0, f′(−½) = 3/2 > 0, f′(½) = −3/2 < 0, f′(2) = 24 > 0.
   - f is decreasing on (−∞, −1) and (0, 1), increasing on (−1, 0) and (1, ∞).
   - By the First Derivative Test: local minima at (−1, 0) and (1, 0), local maximum at (0, 1).
   - **Don't copy its wording.** It says critical points are only where f changes direction, and calls
     the interval test "the first derivative test". For the instructor, a critical number is any interior
     x where f′ = 0 or is undefined, whether or not the sign changes, and the First Derivative Test is
     only for local extrema.
5. **Sketching f′ from a graph of f:** f′ crosses or touches the x-axis where f has a horizontal
   tangent; f′ is above the axis where f rises and below where f falls; f′ is lowest where f falls
   most steeply. If f′ touches 0 but keeps its sign (f levels off and keeps falling), that x is not
   an extremum.

### How to write it up (the instructor's order)
1. Domain, in interval notation.
2. f′(x), simplified to one fraction and factored.
3. f′ = 0 and f′ undefined; keep only interior points of the domain. Critical numbers, then critical points.
4. The test intervals (split at critical numbers and discontinuities), a test value in each, f′ at it, and
   its sign.
5. "f is increasing on (…) and decreasing on (…)", open intervals.
6. If asked for extrema: "By the First Derivative Test, f has a local maximum at x = c", and the point.
- Exact values where possible (34/3, −19/2, −24/5). Decimals only where the problem needs them
  (inverse trig), or beside the exact value as "≈ −4.8".

---

## 7.3 Concavity, points of inflection, Second Derivative Test

Source: the instructor's own 7.3 lecture (Panopto). Example answers checked by hand.

### Definitions and tests
- **Concave upward** on an interval: f′ is increasing, or f″ > 0 there. **Concave downward:** f′ is
  decreasing, or f″ < 0.
- **Test for concavity:** f twice differentiable on the interval. f″(x) > 0 for all x in it means
  concave upward; f″(x) < 0 means concave downward.
- **Point of inflection:** a point (c, f(c)) on the graph where f″(c) = 0 or f″(c) doesn't exist, **and**
  the concavity changes at c, **and** c is in the domain. Here c is any real number, not a critical number.
  f″ = 0 without a change in concavity is not an inflection point (x⁴ at 0).
- **Second Derivative Test** (for local extrema): c is a critical number with **f′(c) = 0**, and f″ exists
  on an open interval containing c.
  - f″(c) > 0: concave upward, **local minimum** at c, value f(c).
  - f″(c) < 0: concave downward, **local maximum** at c, value f(c).
  - f″(c) = 0: **the test fails**. Use the First Derivative Test.
  - A critical number where **f′(c) doesn't exist** can't use this test. Use the First Derivative Test
    for that one (you may use both tests in one problem, each for its own critical numbers).

### The instructor's rules
- **Domain first**, as always. Discontinuities split the number line too.
- Find **possible points of inflection** (f″ = 0 or f″ undefined, interior to the domain). Don't call them
  inflection points until the sign of f″ is shown to change.
- **Show the test value in f″.** "If you just have greater than zero and I don't know that you tested
  −1, I will not give you points." Write f″(−1) and its sign.
- The conclusion is about f: "f is concave upward on (…)".
- **Never join intervals across a discontinuity.** For p(w) below, write (−∞, −3) and (3, ∞)
  separately, not one interval through ±3.
- An inflection point's y value comes from the **original f**, not f′ or f″.
- For the Second Derivative Test, f″ is evaluated at the critical numbers only (no test intervals). Say
  "By the Second Derivative Test, f has a local maximum at x = c", and give the point.

### The instructor's worked examples
1. **f(x) = x⁴ − 8x³ + 2**, domain ℝ.
   - f′(x) = 4x³ − 24x², f″(x) = 12x² − 48x = 12x(x − 4). f″ is never undefined. Possible points of
     inflection: 0, 4.
   - Intervals (−∞, 0), (0, 4), (4, ∞), tested at −1, 1, 5: f″(−1) = 60 > 0, f″(1) = −36 < 0, f″(5) = 60 > 0.
   - f is concave upward on (−∞, 0) and (4, ∞), concave downward on (0, 4).
   - The concavity changes at both, so the points of inflection are (0, 2) and (4, −254).
2. **p(w) = (w² + 2)/(w² − 9)**, domain w ≠ ±3.
   - u = w² + 2, v = w² − 9, u′ = 2w, v′ = 2w. p′(w) = [2w(w² − 9) − 2w(w² + 2)]/(w² − 9)² = −22w/(w² − 9)².
   - Quotient rule again, with v = (w² − 9)², v′ = 2(w² − 9)(2w) = 4w(w² − 9) by the chain rule:
     p″(w) = [−22(w² − 9)² + 88w²(w² − 9)]/(w² − 9)⁴. Factor out 22(w² − 9) and cancel one factor:
     p″(w) = 22[−(w² − 9) + 4w²]/(w² − 9)³ = 22(3w² + 9)/(w² − 9)³.
   - p″ = 0: 3w² + 9 = 0 has no real solution. p″ undefined at ±3, not in the domain. **No points of
     inflection.**
   - The concavity still has to be found. Intervals (−∞, −3), (−3, 3), (3, ∞), tested at −4, 0, 4: +, −, +.
   - p is concave upward on (−∞, −3) and (3, ∞), concave downward on (−3, 3). The concavity changes at ±3,
     but they aren't in the domain, so there are still no inflection points.
3. **A cubic with p′(x) = 6x² − 12x** (the function isn't stated in the lecture).
   - p″(x) = 12x − 12. p′ = 6x(x − 2) = 0 gives critical numbers 0 and 2 (never undefined).
   - p″(0) = −12 < 0, so concave downward: by the Second Derivative Test, a local maximum at x = 0.
     p″(2) = 12 > 0, so concave upward: a local minimum at x = 2.
   - **Unverified:** the lecture gives the points as (0, −2) and (2, −18). With this p′ and p(0) = −2,
     p(2) = −10. The function was changed during the lecture, so one of the y values is wrong.
4. **g(t) = t²e^(−t)**, domain ℝ.
   - u = t², v = e^(−t), u′ = 2t, v′ = −e^(−t). g′(t) = 2te^(−t) − t²e^(−t) = (2t − t²)/eᵗ.
   - Quotient rule: u = 2t − t², v = eᵗ, u′ = 2 − 2t, v′ = eᵗ. g″(t) = [(2 − 2t)eᵗ − (2t − t²)eᵗ]/(eᵗ)²
     = (t² − 4t + 2)/eᵗ.
   - Critical numbers: g′ = 0 when t(2 − t) = 0, so t = 0 and t = 2. eᵗ is never 0, so g′ always exists.
   - g″(0) = 2 > 0: concave upward, local minimum at (0, 0). g″(2) = −2/e² < 0: concave downward, local
     maximum at (2, 4/e²).

---

## 7.4 Graphing functions (curve sketching)

Source: the instructor's own 7.4 lecture (Panopto). The example and the assigned practice problem were
checked by hand.

### The instructor's guidelines, in this order (the workbook's order differs; use this one)
1. **Domain**, in set or interval notation.
2. **Intercepts** as ordered pairs. y-intercept: x = 0. x-intercepts: y = 0; for a rational function,
   where the numerator is 0 (and the denominator isn't). Give an exact value and an approximation to
   place it: ±2√2 ≈ ±2.83.
3. **Asymptotes.**
   - **Vertical: prove it with the definition.** "Simply setting the denominator to zero is not enough on
     a test." Take a one-sided limit at each value: pick a number just beside it (−2.01 for x → −2⁻),
     give the sign of the top and bottom, and conclude the limit is ∞ or −∞.
   - Write asymptotes as **equations**: "x = −2", "y = 3", never just "−2", since asymptotes are lines.
   - **Horizontal or slant:** end behavior. Take the limit as x → ∞ and x → −∞ by keeping the leading
     terms. One end can't have both a horizontal and a slant asymptote.
4. **Critical numbers and points** (f′ = 0 or undefined, in the domain), as in 7.2.
5. **Possible points of inflection** (f″ = 0 or undefined, in the domain), as in 7.3.
6. **Local extrema: use the Second Derivative Test**, since f″ is already found. The exception: a
   critical number where f′ doesn't exist needs the First Derivative Test.
7. **Sketch** with everything: intercepts, asymptotes as dashed lines, extrema, concavity, arrows on the ends.

### The instructor's worked example: f(x) = 3(x² − 8)/(x² − 4)
- Domain: all x ≠ ±2.
- y-intercept (0, 6). x-intercepts: x² − 8 = 0, x = ±2√2 ≈ ±2.83, so (−2√2, 0) and (2√2, 0).
- Vertical asymptotes: x → −2⁻ (x = −2.01): top negative, bottom positive, limit −∞. x → 2⁺ (x = 2.01):
  top negative, bottom positive, limit −∞. So x = −2 and x = 2.
- Horizontal asymptote: leading terms 3x²/x² → 3 as x → ±∞, so y = 3.
- f′(x) = [6x(x² − 4) − 3(x² − 8)(2x)]/(x² − 4)² = 24x/(x² − 4)². f′ = 0 at x = 0. f′ undefined at ±2, not in
  the domain. Critical number 0, critical point (0, 6).
- f″(x) = −24(3x² + 4)/(x² − 4)³ (quotient rule with v = (x² − 4)², v′ = 4x(x² − 4), then cancel one
  factor). f″ = 0 has no real solution; ±2 aren't in the domain. **No points of inflection.**
- f″(0) = 3/2 > 0, concave upward: by the Second Derivative Test, a local minimum at (0, 6).
- Also true, and shown on the sketch: f is decreasing on (−∞, −2) and (−2, 0), increasing on (0, 2) and
  (2, ∞); concave upward on (−2, 2), concave downward on (−∞, −2) and (2, ∞).
- The lecture says the concavity can't be discussed with no inflection points. That's a slip: in 7.3 the
  instructor finds the concavity of a function with none, using the discontinuities to make the intervals.
  Give the concavity.

### The assigned practice problem: f(x) = (x² − 2x + 4)/(x − 2) (worked here, not in the lecture)
- Domain: all x ≠ 2.
- y-intercept (0, −2). x-intercepts: none (x² − 2x + 4 = 0 has discriminant −12 < 0).
- Vertical asymptote x = 2: the top is 4 > 0 there. x → 2⁻: bottom negative, limit −∞. x → 2⁺: bottom
  positive, limit ∞.
- Slant asymptote: long division gives f(x) = x + 4/(x − 2), so y = x as x → ±∞. No horizontal asymptote.
- f′(x) = [(2x − 2)(x − 2) − (x² − 2x + 4)(1)]/(x − 2)² = (x² − 4x)/(x − 2)² = x(x − 4)/(x − 2)². Critical
  numbers 0 and 4 (2 isn't in the domain). Critical points (0, −2) and (4, 6).
- f″(x) = 8/(x − 2)³. Never 0; undefined only at 2, not in the domain. No points of inflection.
- f″(0) = −1 < 0: local maximum at (0, −2). f″(4) = 1 > 0: local minimum at (4, 6).
- Increasing on (−∞, 0) and (4, ∞), decreasing on (0, 2) and (2, 4). Concave downward on (−∞, 2), concave
  upward on (2, ∞).

---

## Module 8 learning objectives (Canvas, "Modules 8" page)

The symbols in the pasted copy were garbled; the forms in brackets are the standard ones they stand for.

1. State the **primary equation** (objective function) and the **secondary equation** (constraint).
2. Solve maximum and minimum problems (optimization).
3. Find the **linear approximation** to a function at a point.
4. Find the **differential** of a function using differentiation rules.
5. Apply L'Hôpital's Rule for the indeterminate form **0/0**.
6. Apply L'Hôpital's Rule for the indeterminate form [**∞/∞**].
7. Apply L'Hôpital's Rule for the indeterminate forms [**1^∞, 0⁰, ∞⁰**] (take the natural log first).
8. Find a method to evaluate the indeterminate form [**∞ − ∞**] (combine into one fraction first).
9. Understand and use **Rolle's Theorem**.
10. Understand and use the **Mean Value Theorem**.
11. Recognize applications of the Mean Value Theorem.

---

## Module 8 lecture notes (the instructor's PDF, 22 pages)

Source: "Module 8 Lecture Notes" on Canvas. The examples are left blank in the notes for students to
work; every answer below was worked here and checked numerically. Typos in the notes are flagged.

### 8.1 Optimization

**The instructor's guidelines:**
1. Read carefully, identify the quantities, and **draw a sketch with the sides labeled (required)**.
2. Write the **primary equation** (objective function): the quantity to maximize or minimize.
3. Write the **secondary equation** (constraint), if the primary equation has more than one variable.
4. Write the primary equation in **one variable** and state a **reasonable domain** in interval or set
   notation.
5. Find its derivative and **all critical numbers**, showing the work. Give the critical number with its
   **unit**: "CN: x = 100 m".
6. **Prove it's the maximum or minimum** (Second Derivative Test, or the First Derivative Test), then
   **conclude in a sentence with units**.

**Example 1: least fencing for 20,000 m² beside a river** (no fence on the river side).
- Sketch: x for each side perpendicular to the river, y for the side parallel to it.
- Primary: F = 2x + y. Secondary: xy = 20,000, so y = 20,000/x.
- F(x) = 2x + 20,000/x, domain (0, ∞).
- F′(x) = 2 − 20,000/x². F′ = 0: x² = 10,000, so CN: x = 100 m (F′ undefined at 0, not in the domain).
- F″(x) = 40,000/x³, and F″(100) > 0, so by the Second Derivative Test it's a minimum.
- y = 200 m. "The least fencing is 400 meters: two 100 m sides and a 200 m side parallel to the river."

**Example 2: largest square-based box with length + width + height ≤ 72.**
- Sketch: base w by w, height h. Primary: V = w²h. Secondary: 2w + h = 72, so h = 72 − 2w.
- V(w) = w²(72 − 2w) = 72w² − 2w³, domain (0, 36).
- V′(w) = 144w − 6w² = 6w(24 − w). CN: w = 24 (0 is not in the domain).
- V″(w) = 144 − 12w, and V″(24) = −144 < 0, so it's a maximum.
- h = 24. "The box of greatest volume is 24 by 24 by 24 units, with volume 13,824 cubic units."

**Practice: two positive numbers with product 192 and the smallest sum.**
- Primary: S = x + y. Secondary: xy = 192, y = 192/x. S(x) = x + 192/x on (0, ∞).
- S′(x) = 1 − 192/x² = 0 gives x = √192 = 8√3 ≈ 13.86. S″(x) = 384/x³ > 0, so it's a minimum.
- The numbers are 8√3 and 8√3, with sum 16√3 ≈ 27.71.

**From the instructor's 8.1 lecture (Panopto), the rules:**
- **No picture, no full credit,** whenever there's something to draw. Label it. Number problems (sums and
  products) have nothing to draw and no units.
- **Know which equation is primary:** the quantity being maximized or minimized. "On the test I can flip
  it around": one version asks for the smallest sum given the product, another for the largest product
  given the sum.
- **The domain comes from the constraints.** x > 0 and y = 51 − x > 0 give 0 < x < 51, so (0, 51).
- A critical number must be **in the open-interval domain**; discard the negative root, and x = 0 if
  it's outside.
- **Use the Second Derivative Test if you can; the First Derivative Test is allowed**, "it just takes more
  time." Writing "F″(50√2) > 0" with its sign is enough.
- **Local to absolute:** "by the Second Derivative Test there's a local minimum, and since it's the only
  extremum on the interval, it's the absolute minimum."
- Get the other variable from the **secondary equation already solved** for it (y = 172/x), not the
  original wording.
- **Answer what's asked.** "The least amount of fencing" is the total, 2x + y, not just the dimensions.
- **Units:** the lengths are meters, not square meters. Rationalizing (100√2 rather than 200/√2) is optional.
- Know the area and perimeter of rectangles and squares.
- **Distance problems (instructor tip, Canvas):** once the distance is written in terms of x,
  d = √(…), the smallest d happens where the expression under the radical is smallest. So let f(x) be the
  expression under the radical, find f′(x) and its critical numbers, and test for the minimum with the
  First or Second Derivative Test. Then put x back in to get the point, and take the square root for the
  distance.
  - Example (worked here, not the instructor's): the point on y = √x closest to (4, 0). Primary:
    d = √((x − 4)² + (y − 0)²); secondary: y = √x, so d = √((x − 4)² + x). Let f(x) = (x − 4)² + x =
    x² − 7x + 16 on [0, ∞). f′(x) = 2x − 7 = 0 gives CN: x = 7/2. f″(x) = 2 > 0, a minimum. The point is
    (7/2, √(7/2)), and the least distance is √f(7/2) = √(15/4) = √15/2 ≈ 1.94.

**The instructor's lecture examples:**
1. **Two positive numbers with product 172 and the smallest sum.** S = x + y (primary), xy = 172
   (secondary), y = 172/x. S(x) = x + 172x⁻¹, domain {x | x > 0}. S′(x) = 1 − 172/x² = (x² − 172)/x²; S′ = 0
   gives x = ±√172, and x > 0, so CN: x = √172 (S′ undefined only at 0, not in the domain).
   S″(x) = 344/x³ > 0 at √172, concave upward, so a minimum. The sum is minimal when x = √172 and
   y = 172/√172 = √172 (= 2√43 ≈ 13.11).
2. **Two positive numbers with sum 51 and the largest product.** P = xy (primary), x + y = 51 (secondary),
   y = 51 − x. y > 0 gives x < 51, so domain (0, 51). P(x) = 51x − x² (distribute instead of the product
   rule). P′(x) = 51 − 2x = 0 gives CN: x = 51/2, inside (0, 51). P″(x) = −2 < 0, concave downward, so a
   maximum. The product is maximal when x = 51/2 and y = 51/2.
3. **Least fencing for 10,000 m² beside a river.** Sketch: x for the two sides off the river, y along it.
   F = 2x + y (primary), xy = 10,000 (secondary), y = 10,000/x. F(x) = 2x + 10,000x⁻¹, domain x > 0.
   F′(x) = 2 − 10,000/x² = (2x² − 10,000)/x²; x² = 5,000, CN: x = √5,000 = 50√2 m ≈ 70.71 m.
   F″(x) = 20,000/x³ > 0, a minimum. y = 10,000/(50√2) = 200/√2 = 100√2 m. **The least fencing is
   2(50√2) + 100√2 = 200√2 meters ≈ 282.84 m.**

**From the two Week 10 YouTube optimization videos (checked; the instructor's rules above still apply):**
4. **Open-top box, volume 972 in³, base twice as long as wide; minimize surface area.**
   Sketch: width x, length 2x, height h. Secondary: 2x · x · h = 972, so h = 486/x². Primary (no top):
   A = 2x² + 2(xh) + 2(2xh) = 2x² + 6xh, so A(x) = 2x² + 2,916/x on (0, ∞). A′(x) = 4x − 2,916/x² = 0 gives
   x³ = 729, CN: x = 9 in (0 is excluded: not in the domain). A′(8) < 0 and A′(10) > 0, so by the First
   Derivative Test a minimum (or A″(x) = 4 + 5,832/x³ > 0). The box is 9 in by 18 in by 6 in, with
   surface area 486 in².
5. **Open box from a 20 in by 32 in sheet, equal squares of side x cut from the corners; maximize volume.**
   Sketch the sheet with the corner squares. Length 32 − 2x, width 20 − 2x, height x.
   V(x) = x(32 − 2x)(20 − 2x) = 4x³ − 104x² + 640x. **Domain (0, 10)**: x can't be 0, and 2x must be less
   than the 20 in width. V′(x) = 12x² − 208x + 640 = 4(3x − 40)(x − 4), giving 40/3 and 4; **40/3 is
   outside (0, 10)**, so CN: x = 4 in. V′(3) > 0 and V′(5) < 0 (First Derivative Test), or
   V″(x) = 24x − 208, V″(4) = −112 < 0 (Second Derivative Test): a maximum. V(4) = 4 · 24 · 12 =
   **1,152 in³**, in cubic units. *(The transcript says V″(4) = −12; it's −112. The video also notes that
   the closed-interval method can't be used here, since the domain is an open interval.)*
- Both videos call the critical numbers "critical points". The instructor uses "critical number" for x.

### 8.2 Linear approximation and differentials

- **Linear approximation** at a: L(x) = f(a) + f′(a)(x − a), the tangent line, and f(x) ≈ L(x).
- **Error:** E(x) = f(x) − [f(a) + f′(a)(x − a)].
- **Overestimate** if f″(a) < 0 (concave down). **Underestimate** if f″(a) > 0 (concave up). Justify
  with the sign of f″(a).
- **Differentials:** Δx = dx, dy = f′(x)dx, Δy = f(x + Δx) − f(x), and Δy ≈ dy.

Worked:
- **f(x) = ∛x at x = 8:** f(8) = 2, f′(x) = 1/(3x^(2/3)), f′(8) = 1/12, so L(x) = 2 + (1/12)(x − 8).
  f″(x) = −2/(9x^(5/3)) and f″(8) < 0, so it's an **overestimate**. ∛8.6 ≈ L(8.6) = 2 + 0.6/12 = 2.05
  (actual 2.0488).
- **√50:** a = 49 (the nearest perfect square), f(x) = √x, f′(49) = 1/14. √50 ≈ 7 + 1/14 ≈ 7.0714
  (actual 7.0711).
- **Δy vs dy for y = x², x from 1.00 to 1.02:** dx = 0.02, dy = 2x dx = 2(1)(0.02) = 0.04;
  Δy = 1.02² − 1² = 0.0404, a difference of 0.0004. *(The notes print "2(1.0)(0.02) −0.04"; it's "= 0.04".)*
- **y = 4/x² = 4x⁻²:** dy = −8x⁻³ dx = −(8/x³) dx. *(The notes drop the minus sign: dy/dx = −8x⁻³.)*
- **g(w) = 5 tan w:** dg = 5 sec²w dw.
- **p(θ) = θ³ ln(sin 8θ):** product and chain rules: dp = [3θ² ln(sin 8θ) + 8θ³ cot 8θ] dθ.
- **h(x) = 4e^(3x) − 5 csc(πx)** (the notes' text reads "5acsc(πx)"; csc assumed):
  dh = [12e^(3x) + 5π csc(πx) cot(πx)] dx. If it's arccsc(πx), the second term is
  + 5π/(|πx|√(π²x² − 1)).

### 8.3 L'Hôpital's Rule

- **Indeterminate forms 0/0 and ±∞/±∞:** lim f/g = lim f′/g′. The derivatives of the top and bottom
  **separately** (not the quotient rule), and it may be applied more than once.
- **Only for an indeterminate form.** Check the form first and write it down. Otherwise the rule gives a
  wrong answer: lim (x → 3) (x² − 9)/(x + 3) = 0/6 = 0 by substitution, and the rule wrongly gives 6.
  *(The notes write the denominator as x + 3 in one line and x − 3 in the next.)*
- The earlier techniques still work for some: cancellation (x² − 4)/(x − 2) → 4; leading terms for ∞/∞.
- **0·∞:** rewrite fg as f/(1/g) or g/(1/f), then apply the rule.
- **∞ − ∞:** combine into one fraction (common denominator, rationalize, or factor), then evaluate.
- **0⁰, ∞⁰, 1^∞:** let y be the limit's function, take ln y, evaluate lim ln y (a 0·∞ form), and the
  answer is e to that.

Worked:
- lim (x → 0) (eˣ − 1)/(x(x + 2)): 0/0, so eˣ/(2x + 2) → **1/2**.
- lim (x → 0) sin 5x/(3x): 0/0, so 5 cos 5x/3 → **5/3**.
- lim (x → 0) x³/(sin x − x): 0/0 three times: 3x²/(cos x − 1), then 6x/(−sin x), then 6/(−cos x) → **−6**.
- lim (w → ∞) w²/eʷ: ∞/∞ twice: 2w/eʷ, then 2/eʷ → **0**.
- lim (x → 0⁺) x ln x: 0·(−∞). Rewrite ln x/(1/x): (1/x)/(−1/x²) = −x → **0**.
- lim (x → 0⁺) (10/x − 3/x²): ∞ − ∞. One fraction: (10x − 3)/x², which is −3/0⁺, so **−∞**. It isn't
  indeterminate after combining, so no L'Hôpital.
- lim (x → 2⁺) [8/(x² − 4) − x/(x − 2)]: ∞ − ∞. Common denominator: (8 − x² − 2x)/(x² − 4)
  = −(x + 4)(x − 2)/((x − 2)(x + 2)) = −(x + 4)/(x + 2) → **−3/2** (L'Hôpital on the 0/0 gives the same).
- lim (x → 0⁺) x^(3x): 0⁰. ln y = 3x ln x → 0, so the limit is e⁰ = **1**.
- lim (x → ∞) (1 + 1/x)^(2x): 1^∞. ln y = 2 ln(1 + 1/x)/(1/x), a 0/0, which → 2, so the limit is **e²**.

### 8.4 Mean Value Theorem and Rolle's Theorem

- **MVT:** f continuous on [a, b] and differentiable on (a, b) ⟹ some c in (a, b) has
  f′(c) = [f(b) − f(a)]/(b − a).
- **Rolle's Theorem:** f continuous on [a, b], differentiable on (a, b), **and f(a) = f(b)** ⟹ some c in
  (a, b) has f′(c) = 0.
- **Show the hypotheses each time** ("f is continuous on [1, 2]", "differentiable on (1, 2)", and for
  Rolle "f(1) = 64 = f(2)") before using the theorem. If one fails, say which and that it doesn't apply.
- Keep only the c values **inside (a, b)**.

Worked:
- **f(x) = 1/(x − 1) on [−1, 2]:** not continuous at x = 1, which is in [−1, 2], so **the MVT doesn't apply**.
- **f(x) = eˣ on [0, ln 4]:** continuous and differentiable everywhere. [f(ln 4) − f(0)]/(ln 4 − 0) =
  3/ln 4. eᶜ = 3/ln 4, so c = ln(3/ln 4) ≈ 0.772, which is in (0, ln 4 ≈ 1.386).
- **Troopers 50 miles apart, 20 minutes:** s(t) is continuous and differentiable, so by the MVT some
  s′(t) equals the average rate (50 − 0)/(20 − 0) = 50/20 mi/min × 60 min/hr = **150 mph**. The car
  went 150 mph at some point.
- **Rolle, f(x) = x(x − 1)² on [0, 1]:** a polynomial, so continuous and differentiable; f(0) = 0 = f(1).
  f′(x) = (x − 1)² + 2x(x − 1) = (x − 1)(3x − 1) = 0 gives c = 1/3 (1 is not in (0, 1)).
- **Rolle, f(x) = x⁴ − 2x² on [−2, 3]:** f(−2) = 8 and f(3) = 63 aren't equal, so **Rolle's Theorem
  doesn't apply**.
- **Ball, s(t) = −16t² + 48t + 32 on [1, 2]:** continuous, s′(t) = −32t + 48 so differentiable,
  s(1) = 64 = s(2). The velocity is 0 at t = 3/2 = 1.5 s. *(The notes print s(1) = 74 = s(2); both are 64.)*
- **Cost C(x) = 10(1/x + x/(x + 3)) on [3, 6]:** continuous on [3, 6]; C′(x) = 10(−1/x² + 3/(x + 3)²)
  = 10(2x² − 6x − 9)/(x²(x + 3)²), so differentiable on (3, 6); C(3) = 25/3 = C(6). 2x² − 6x − 9 = 0
  gives x = (3 ± 3√3)/2, and only (3 + 3√3)/2 ≈ 4.098 is in (3, 6): an order of about 410 components.

---

## Still needed
- 7.1: the instructor's lecture or notes (absolute and local extrema, closed interval method). From the
  first Week 10 video only: on a closed interval [a, b], find the critical numbers, then put them **and the
  endpoints** into f; the largest value is the absolute maximum and the smallest the absolute minimum.
  An endpoint can be an absolute extremum but never a local one (instructor, 7.2).
- The instructor's lectures for 8.2 to 8.4, if any, for grading rules beyond the notes
  ("Module 7: Definitions, Guidelines and Procedures, and Theorems" and "Module 8 Lecture Notes").
- Math 131 Practice Test 3 (PDF), and its key if there is one. It shows the format and how work is graded.
- Anything in the instructor's own grading that differs from the textbook.
