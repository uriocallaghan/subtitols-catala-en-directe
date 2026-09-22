import Foundation

public enum WordErrorRate {
    public static func score(reference: String, hypothesis: String) -> Double {
        let expected = words(in: reference)
        let actual = words(in: hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }

        var previous = Array(0...actual.count)
        for (referenceIndex, referenceWord) in expected.enumerated() {
            var current = [referenceIndex + 1]
            current.reserveCapacity(actual.count + 1)
            for (actualIndex, actualWord) in actual.enumerated() {
                let substitution = previous[actualIndex]
                    + (referenceWord == actualWord ? 0 : 1)
                let insertion = current[actualIndex] + 1
                let deletion = previous[actualIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
