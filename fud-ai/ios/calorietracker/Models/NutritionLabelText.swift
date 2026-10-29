import CoreGraphics
import Foundation

/// Text that Vision read from one photo, as label rows top to bottom.
nonisolated struct NutritionLabelPhotoText: Equatable, Sendable {
    /// 1-based position of the photo in the request.
    let photoNumber: Int
    let lines: [String]
}

/// Turns on-device text recognition of a nutrition label into table rows that
/// go into the photo prompt for the on-device models. #486 reports that they
/// miss, misread or misassign label values, so they also get the numbers
/// Vision read. Pure, so the row assembly is unit tested;
/// `NutritionLabelTextRecognizer` runs Vision.
/// iOS only: Android has no on-device text recognizer without adding ML Kit
/// text recognition.
nonisolated enum NutritionLabelText {
    /// One line of text from Vision. `box` uses Vision's normalized
    /// coordinates: origin at the lower left, y grows upward.
    nonisolated struct Fragment: Equatable, Sendable {
        var text: String
        var box: CGRect
        /// The line's rise per unit of x, from the corners Vision reports, or
        /// nil when unknown. See `lineSlope(topLeft:topRight:bottomLeft:bottomRight:)`.
        var slope: CGFloat? = nil
    }

    static let columnSeparator = " | "
    /// Photos read per request; later photos are sent without label text.
    static let maxPhotos = 4
    static let maxLinesPerPhoto = 60
    /// Keeps the label text well inside the 4,096-token context of the
    /// on-device models, next to the photo prompt, the photos and the reply,
    /// even for scripts that spend a token per character.
    static let maxCharacters = 1_200
    /// A label has several numeric rows; a scale reading or a price tag does not.
    static let minimumNumericLines = 3

    /// Groups fragments into rows from top to bottom. Each row's cells run in
    /// reading order and are joined with `columnSeparator`, so a nutrient name
    /// stays on the same line as its values. A unit that Vision read as its own
    /// fragment ("8" then "g") is joined to its number.
    static func lines(from fragments: [Fragment]) -> [String] {
        let kept = fragments.compactMap { fragment -> Fragment? in
            var fragment = fragment
            fragment.text = collapsingWhitespace(fragment.text)
            guard !fragment.text.isEmpty, fragment.box.height > 0 else { return nil }
            return fragment
        }
        // A tilted photo slants every row the same way. Leveling the rows keeps
        // a value at the far right on its nutrient's row.
        let skew = estimatedSkew(of: kept)
        let cells = kept.map { Cell(fragment: $0, level: level(of: $0, skew: skew)) }
        // Vision's y grows upward, so the top of the label has the largest level.
        let ordered = cells.sorted {
            $0.level != $1.level ? $0.level > $1.level : $0.fragment.box.minX < $1.fragment.box.minX
        }
        var rows: [Row] = []
        for cell in ordered {
            let match = rows.indices
                .compactMap { index in rows[index].distance(to: cell).map { (index: index, distance: $0) } }
                .min { $0.distance < $1.distance }
            if let match {
                rows[match.index].cells.append(cell)
            } else {
                rows.append(Row(cells: [cell]))
            }
        }
        let rightToLeft = isRightToLeft(kept.map(\.text))
        return rows.map { $0.line(rightToLeft: rightToLeft) }
    }

    /// True when the rows read like a nutrition panel: an energy amount
    /// (kcal, kJ or calories) and several numeric rows.
    static func isLikelyNutritionLabel(_ lines: [String]) -> Bool {
        guard lines.filter(hasNumber).count >= minimumNumericLines else { return false }
        return lines.contains { line in
            line.range(of: energyMarkerPattern, options: [.regularExpression, .caseInsensitive]) != nil
                || cjkEnergyUnits.contains { line.contains($0) }
        }
    }

    /// The prompt section for the on-device models, or nil when no photo has
    /// label text. Only rows with a number are sent: the row assembly keeps
    /// each nutrient's name on its value's row, and titles, ingredient lists
    /// and marketing copy would only spend the small context. Keeps at most
    /// `maxLinesPerPhoto` rows of a photo and stops at the first row past
    /// `maxCharacters`, so the text never skips a row.
    static func promptSection(for photos: [NutritionLabelPhotoText]) -> String? {
        var remaining = maxCharacters
        var blocks: [String] = []
        var budgetSpent = false
        for photo in photos where !budgetSpent {
            var kept: [String] = []
            for line in photo.lines.filter(hasNumber).prefix(maxLinesPerPhoto) {
                guard line.count < remaining else {
                    budgetSpent = true
                    break
                }
                kept.append(line)
                remaining -= line.count + 1
            }
            guard !kept.isEmpty else { continue }
            blocks.append("Photo \(photo.photoNumber):\n" + kept.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return nil }
        return """
        NUTRITION LABEL TEXT
        On-device text recognition read these lines from the nutrition label, top to bottom. "|" separates the label's columns.
        \(blocks.joined(separator: "\n"))
        Prefer these recognized numbers over digits read from the image. Give each value to the nutrient named on the same line. Use the image to tell which column is per serving and which is per 100 g or 100 ml, and to correct clear recognition mistakes, such as "g" read as "9" or "O" read as "0".
        """
    }

    /// `prompt` followed by the label section, or `prompt` unchanged without one.
    static func prompt(_ prompt: String, adding section: String?) -> String {
        guard let section else { return prompt }
        return prompt + "\n\n" + section
    }

    // MARK: - Rows

    nonisolated private struct Cell {
        let fragment: Fragment
        /// Vertical center after leveling the photo's tilt.
        let level: CGFloat
    }

    nonisolated private struct Row {
        var cells: [Cell]

        /// How far `cell` sits from the row's horizontally nearest cell, or nil
        /// when that is more than half the smaller text height. Comparing with
        /// the nearest cell lets a row follow tilt that leveling left over.
        /// Nil as well when the row already has a cell in the same column, as
        /// a steep photo's tall boxes can bring stacked names within reach.
        func distance(to cell: Cell) -> CGFloat? {
            let box = cell.fragment.box
            guard !cells.contains(where: { $0.fragment.box.minX < box.maxX && box.minX < $0.fragment.box.maxX }) else {
                return nil
            }
            let midX = box.midX
            guard let nearest = cells.min(by: {
                abs($0.fragment.box.midX - midX) < abs($1.fragment.box.midX - midX)
            }) else { return nil }
            let distance = abs(nearest.level - cell.level)
            return distance <= min(nearest.fragment.box.height, cell.fragment.box.height) / 2 ? distance : nil
        }

        func line(rightToLeft: Bool) -> String {
            let fragments = cells.map(\.fragment).sorted { $0.box.minX < $1.box.minX }
            // Units join their numbers from left to right, as printed: a Latin
            // unit sits right of its number even in an Arabic or Hebrew row.
            var parts: [(text: String, maxX: CGFloat)] = []
            for fragment in fragments {
                if let last = parts.last, last.text.last?.isNumber == true, NutritionLabelText.isBareUnit(fragment.text) {
                    parts[parts.count - 1] = (last.text + " " + fragment.text, max(last.maxX, fragment.box.maxX))
                } else {
                    parts.append((fragment.text, fragment.box.maxX))
                }
            }
            if rightToLeft {
                parts.sort { $0.maxX > $1.maxX }
            }
            return parts.map(\.text).joined(separator: NutritionLabelText.columnSeparator)
        }
    }

    // MARK: - Tilt

    /// Steepest tilt tried, as rise per unit of x; about 15 degrees on a portrait photo.
    private static let maxSkew: CGFloat = 0.2
    private static let skewStep: CGFloat = 0.0025
    /// A tilt far from the text lines' own slope wins only when it scores one
    /// full pair more than the best tilt near it, plus this share of that score.
    private static let farSkewMargin: CGFloat = 0.25

    /// The rise per unit of x of a line whose corners Vision reports in
    /// normalized coordinates: the mean of its top and bottom edges. Nil
    /// when an edge does not run left to right, as with vertical text.
    static func lineSlope(topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) -> CGFloat? {
        let topWidth = topRight.x - topLeft.x
        let bottomWidth = bottomRight.x - bottomLeft.x
        guard topWidth > 0, bottomWidth > 0 else { return nil }
        let slope = ((topRight.y - topLeft.y) / topWidth + (bottomRight.y - bottomLeft.y) / bottomWidth) / 2
        return slope.isFinite ? slope : nil
    }

    /// Vertical center after removing `skew`.
    private static func level(of fragment: Fragment, skew: CGFloat) -> CGFloat {
        fragment.box.midY - skew * fragment.box.midX
    }

    /// The tilt that best lines up side-by-side fragments into rows. Each
    /// pair scores 1 when its leveled centers match, falling to 0 at half the
    /// smaller text height. A label with one column stays level.
    ///
    /// The pairs alone cannot tell a level label from one tilted by a whole
    /// row: both line up almost every nutrient with a value, and with gaps in
    /// a column, such as a %DV column, they line up just as many. So the
    /// search prefers tilts near the slope of the text lines themselves:
    /// within half a text height of it across the widest pair, so they cannot
    /// carry a value to the next row. A tilt farther away wins only when it
    /// lines up clearly more pairs (`farSkewMargin`).
    private static func estimatedSkew(of fragments: [Fragment]) -> CGFloat {
        // Fragments stacked in the same column never share a row, and pairs
        // too far apart vertically cannot line up at any tilt in range.
        var pairs: [(dx: CGFloat, dy: CGFloat, tolerance: CGFloat)] = []
        for (index, first) in fragments.enumerated() {
            for second in fragments[(index + 1)...] {
                guard first.box.maxX <= second.box.minX || second.box.maxX <= first.box.minX else { continue }
                let dx = second.box.midX - first.box.midX
                let dy = second.box.midY - first.box.midY
                let tolerance = min(first.box.height, second.box.height) / 2
                if abs(dy) < maxSkew * abs(dx) + tolerance { pairs.append((dx, dy, tolerance)) }
            }
        }
        guard let widest = pairs.map({ abs($0.dx) }).max(), widest > 0 else { return 0 }
        func score(_ skew: CGFloat) -> CGFloat {
            pairs.reduce(0) { total, pair in
                let gap = abs(pair.dy - skew * pair.dx)
                return gap < pair.tolerance ? total + 1 - gap / pair.tolerance : total
            }
        }
        let expected = textLineSlope(of: fragments)
        let tolerances = pairs.map(\.tolerance).sorted()
        // Near tilts move even the widest pair by at most a typical
        // tolerance, half a text height, away from the lines' slope.
        let reach = tolerances[tolerances.count / 2] / widest
        let steps = Int((maxSkew / skewStep).rounded())
        // Nearest to the expected slope first, so ties keep the nearer tilt.
        let skews = (-steps...steps).map { CGFloat($0) * skewStep }
            .sorted { abs($0 - expected) < abs($1 - expected) }
        var near: (skew: CGFloat, score: CGFloat)?
        var far: (skew: CGFloat, score: CGFloat)?
        for skew in skews {
            let value = score(skew)
            // The nearest tilt always counts as near, however small `reach` is.
            if near == nil || abs(skew - expected) <= reach {
                if value > (near?.score ?? -1) + 1e-9 { near = (skew, value) }
            } else if value > (far?.score ?? -1) + 1e-9 {
                far = (skew, value)
            }
        }
        guard let near else { return 0 }
        if let far, far.score >= near.score + 1 + farSkewMargin * near.score { return far.skew }
        return near.skew
    }

    /// The text lines' own slope: the median of the slopes Vision reported,
    /// weighted by line width, as wider lines give steadier angles. Vision
    /// gives many short lines an exactly level box whatever the tilt, so a
    /// slope of exactly 0 does not count. 0 when no line reports a slope.
    private static func textLineSlope(of fragments: [Fragment]) -> CGFloat {
        let lines = fragments.compactMap { fragment in
            fragment.slope.flatMap { $0 == 0 ? nil : (slope: $0, weight: fragment.box.width) }
        }.sorted { $0.slope < $1.slope }
        let half = lines.reduce(0) { $0 + $1.weight } / 2
        guard half > 0 else { return 0 }
        var weight: CGFloat = 0
        for line in lines {
            weight += line.weight
            if weight >= half { return min(max(line.slope, -maxSkew), maxSkew) }
        }
        return 0
    }

    // MARK: - Helpers

    private static let energyMarkerPattern = #"(?<!\p{L})(kcal|kj|cal|calories?|ккал|кдж)(?!\p{L})"#
    private static let cjkEnergyUnits = ["千卡", "千焦", "大卡"]
    private static let bareUnits: Set<String> = ["g", "mg", "mcg", "µg", "μg", "kcal", "kj", "cal", "ml", "iu", "%"]

    private static func hasNumber(_ line: String) -> Bool {
        line.contains(where: \.isNumber)
    }

    private static func isBareUnit(_ text: String) -> Bool {
        bareUnits.contains(text.lowercased())
    }

    /// Arabic or Hebrew labels read right to left. A photo counts as right
    /// to left when its words have more of those letters than Latin ones, so
    /// "الطاقة 250 kcal" is right to left and a bilingual "Energy 250 kcal
    /// الطاقة" is not. Numbers and units such as "kcal" read left to right in
    /// every script, so they do not count. One direction for the whole photo
    /// keeps each value column in the same place on every row.
    private static func isRightToLeft(_ texts: [String]) -> Bool {
        var rightToLeft = 0
        var latin = 0
        for text in texts {
            for word in text.split(whereSeparator: \.isWhitespace)
            where !word.contains(where: \.isNumber) && !isBareUnit(String(word)) {
                for scalar in word.unicodeScalars {
                    switch scalar.value {
                    case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                        if scalar.properties.isAlphabetic { rightToLeft += 1 }
                    case 0x41...0x5A, 0x61...0x7A:
                        latin += 1
                    default:
                        break
                    }
                }
            }
        }
        return rightToLeft > latin
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
