/// The math the written answer has to show, one case per line, grouped as the evaluation asks.
/// Math 131 cases come from Courses/MATH131.md (Test 3: sections 7.2 to 8.4).
struct Case {
  let group: String
  let name: String
  let latex: String
}

enum Corpus {
  static let cases: [Case] = [
    // Basics
    Case(group: "Basics", name: "fraction", latex: #"\frac{3}{\ln 4}"#),
    Case(group: "Basics", name: "nested fraction", latex: #"\frac{1}{1 + \frac{1}{x}}"#),
    Case(group: "Basics", name: "square root", latex: #"x = \pm 2\sqrt{2}"#),
    Case(group: "Basics", name: "nth root", latex: #"\sqrt[3]{x^2 + 1}"#),
    Case(group: "Basics", name: "exponents", latex: #"e^{x^2} \cdot x^{-3}"#),
    Case(group: "Basics", name: "subscripts", latex: #"x_1, x_2, a_{n+1}"#),
    Case(group: "Basics", name: "absolute value", latex: #"\left| x - 3 \right| < 2"#),
    Case(group: "Basics", name: "inequalities", latex: #"-2 \le x < 5,\ y \ge 0"#),
    Case(group: "Basics", name: "intervals", latex: #"(-\infty, -2) \cup (-2, 0]"#),
    Case(group: "Basics", name: "Greek and plus-minus", latex: #"\theta = \pm \frac{\pi}{6},\ \Delta y"#),
    Case(group: "Basics", name: "arrows", latex: #"x \to 2^{+} \Rightarrow f(x) \to -\infty"#),
    // Calculus
    Case(group: "Calculus", name: "derivative", latex: #"f'(x) = \frac{24x}{(x^2 - 4)^2}"#),
    Case(group: "Calculus", name: "second derivative", latex: #"f''(x) = \frac{-24(3x^2 + 4)}{(x^2 - 4)^3}"#),
    Case(group: "Calculus", name: "Leibniz", latex: #"\frac{dy}{dx} = \frac{d}{dx}\left[\sin(5x)\right]"#),
    Case(group: "Calculus", name: "limit", latex: #"\lim_{x \to 0} \frac{\sin 5x}{3x} = \frac{5}{3}"#),
    Case(group: "Calculus", name: "integral", latex: #"\int_0^{1} x^2\,dx = \frac{1}{3}"#),
    Case(group: "Calculus", name: "log and trig", latex: #"\ln\left(\frac{3}{\ln 4}\right) + \cos^2\theta"#),
    Case(group: "Calculus", name: "related rates", latex: #"\frac{dV}{dt} = 4\pi r^2 \frac{dr}{dt}"#),
    // Structures
    Case(group: "Structures", name: "matrix", latex: #"\begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}"#),
    Case(group: "Structures", name: "system", latex: #"\begin{cases} 2x + y = 5 \\ x - y = 1 \end{cases}"#),
    Case(group: "Structures", name: "piecewise", latex: #"f(x) = \begin{cases} x^2 & x < 0 \\ \sqrt{x} & x \ge 0 \end{cases}"#),
    Case(group: "Structures", name: "aligned", latex: #"\begin{aligned} 3x + 7 &= 22 \\ 3x &= 15 \\ x &= 5 \end{aligned}"#),
    Case(group: "Structures", name: "boxed answer", latex: #"\boxed{x = \frac{1}{3}}"#),
    // Math 131 Test 3
    Case(group: "Math 131", name: "7.4 quotient rule", latex: #"f'(x) = \frac{6x(x^2 - 4) - 3(x^2 - 8)(2x)}{(x^2 - 4)^2}"#),
    Case(group: "Math 131", name: "8.3 L'Hopital", latex: #"\lim_{x \to 0} \frac{x^3}{\sin x - x} = \lim_{x \to 0} \frac{6}{-\cos x} = -6"#),
    Case(group: "Math 131", name: "8.3 one-to-the-infinity", latex: #"\lim_{x \to \infty}\left(1 + \frac{1}{x}\right)^{2x} = e^{2}"#),
    Case(group: "Math 131", name: "8.4 MVT", latex: #"f'(c) = \frac{f(b) - f(a)}{b - a}"#),
    Case(group: "Math 131", name: "8.4 Rolle", latex: #"f'(x) = (x - 1)^2 + 2x(x - 1) = (x - 1)(3x - 1)"#),
    Case(group: "Math 131", name: "8.1 optimization", latex: #"A(x) = x\left(\frac{1200 - 2x}{2}\right),\ A'(x) = 600 - 2x = 0"#),
    // Long lines (the written answer is about 360 points wide)
    Case(group: "Long", name: "long equation", latex: #"\lim_{x \to 2^{+}} \left[\frac{8}{x^2 - 4} - \frac{x}{x - 2}\right] = \lim_{x \to 2^{+}} \frac{-(x + 4)(x - 2)}{(x - 2)(x + 2)} = -\frac{3}{2}"#),
    Case(group: "Long", name: "long polynomial", latex: #"f(x) = 3x^5 - 20x^4 + 35x^3 - 12x^2 + 7x - 41 + \frac{2}{x} - \frac{5}{x^2}"#),
    // Chemistry
    Case(group: "Chemistry", name: "subscripts by hand", latex: #"\mathrm{H_2SO_4} + 2\,\mathrm{NaOH} \rightarrow \mathrm{Na_2SO_4} + 2\,\mathrm{H_2O}"#),
    Case(group: "Chemistry", name: "charges by hand", latex: #"\mathrm{Fe^{3+}} + \mathrm{SO_4^{2-}}"#),
    Case(group: "Chemistry", name: "mhchem reaction", latex: #"\ce{2H2 + O2 -> 2H2O}"#),
    Case(group: "Chemistry", name: "mhchem equilibrium", latex: #"\ce{CH3COOH <=> CH3COO- + H+}"#),
    Case(group: "Chemistry", name: "mhchem units", latex: #"\pu{1.5 mol L-1}"#),
    // Bad input
    Case(group: "Malformed", name: "unclosed brace", latex: #"\frac{1}{x"#),
    Case(group: "Malformed", name: "unknown command", latex: #"\foo{x} + 1"#),
    Case(group: "Malformed", name: "stray right", latex: #"x + 1 \right)"#),
    Case(group: "Malformed", name: "bad environment", latex: #"\begin{aligned} x &= 1"#),
    // A line as it arrives while Claude is still writing it
    Case(group: "Streaming", name: "stream 1", latex: #"x = \frac"#),
    Case(group: "Streaming", name: "stream 2", latex: #"x = \frac{2"#),
    Case(group: "Streaming", name: "stream 3", latex: #"x = \frac{2}{3"#),
    Case(group: "Streaming", name: "stream 4", latex: #"x = \frac{2}{3}"#),
  ]
}
