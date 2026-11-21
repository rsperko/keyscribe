import Foundation

public enum SpokenNumber {
    public enum Form: Sendable { case whole, grouped, digits }

    public struct Read: Equatable, Sendable {
        public var value: Int?
        public var words: Int

        public init(value: Int?, words: Int) {
            self.value = value
            self.words = words
        }
    }

    public static func read(_ words: ArraySlice<String>, forms: Set<Form>) -> Read? {
        let run = Array(words.prefix(runLength(words)))
        guard !run.isEmpty else { return nil }
        let value = [Form.whole, .grouped, .digits].lazy.filter(forms.contains).compactMap { form -> Int? in
            switch form {
            case .whole: whole(run)
            case .grouped: grouped(run)
            case .digits: digits(run)
            }
        }.first
        return Read(value: value, words: run.count)
    }

    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let longestDigits = 15

    private enum Word {
        case unit(Int), teen(Int), tens(Int), hundred, thousand, numeral(String)

        init?(_ word: String) {
            if let unit = SpokenNumber.units.firstIndex(of: word) { self = .unit(unit) }
            else if let teen = SpokenNumber.teens.firstIndex(of: word) { self = .teen(10 + teen) }
            else if let ten = SpokenNumber.tens.firstIndex(of: word) { self = .tens(20 + 10 * ten) }
            else if word == "hundred" { self = .hundred }
            else if word == "thousand" { self = .thousand }
            else if !word.isEmpty, word.allSatisfy(\.isASCII), word.allSatisfy(\.isNumber) { self = .numeral(word) }
            else { return nil }
        }

        var startsANumber: Bool {
            switch self {
            case .hundred, .thousand: false
            default: true
            }
        }
    }

    private static func runLength(_ words: ArraySlice<String>) -> Int {
        guard let first = words.first.flatMap(Word.init), first.startsANumber else { return 0 }
        var end = words.startIndex + 1
        while end < words.endIndex {
            if Word(words[end]) != nil {
                end += 1
            } else if words[end] == "and", end + 1 < words.endIndex, ["hundred", "thousand"].contains(words[end - 1]),
                      Word(words[end + 1])?.startsANumber == true {
                end += 2
            } else {
                break
            }
        }
        return end - words.startIndex
    }

    private static func whole(_ run: [String]) -> Int? {
        if run.count == 1, case .numeral(let numeral)? = Word(run[0]) { return numeral.count <= longestDigits ? Int(numeral) : nil }
        enum Last { case none, unit, teen, tens, hundred, scale }
        var total = 0, group = 0, last = Last.none
        for (index, said) in run.enumerated() {
            if said == "and" {
                guard last == .hundred || last == .scale else { return nil }
                continue
            }
            var word = Word(said)
            if run.count > 1, case .numeral(let numeral)? = word, let value = Int(numeral), value < 100, String(value) == numeral {
                word = value < 10 ? .unit(value) : value % 10 == 0 && value >= 20 ? .tens(value) : .teen(value)
            }
            switch word {
            case .unit(let unit)?:
                guard unit > 0 || run.count == 1, [.none, .tens, .hundred, .scale].contains(last) else { return nil }
                group += unit
                last = .unit
            case .teen(let teen)?:
                guard [.none, .hundred, .scale].contains(last) else { return nil }
                group += teen
                last = .teen
            case .tens(let ten)?:
                guard [.none, .hundred, .scale].contains(last) else { return nil }
                group += ten
                last = .tens
            case .hundred?:
                guard last == .unit, group < 10 else { return nil }
                group *= 100
                last = .hundred
            case .thousand?:
                guard last != .none, last != .scale, total == 0, index > 0 else { return nil }
                total = group * 1000
                group = 0
                last = .scale
            case .numeral?, nil:
                return nil
            }
        }
        return total + group
    }

    private static func grouped(_ run: [String]) -> Int? {
        var groups: [Int] = []
        var index = 0
        while index < run.count {
            switch Word(run[index]) {
            case .tens(let ten)?:
                if index + 1 < run.count, case .unit(let unit)? = Word(run[index + 1]), unit > 0 {
                    groups.append(ten + unit)
                    index += 2
                } else {
                    groups.append(ten)
                    index += 1
                }
            case .unit(let unit)?: groups.append(unit); index += 1
            case .teen(let teen)?: groups.append(teen); index += 1
            case .numeral(let numeral)? where numeral.count <= 2: groups.append(Int(numeral)!); index += 1
            default: return nil
            }
        }
        guard groups.count > 1, (1...99).contains(groups[0]), groups.dropFirst().allSatisfy({ (10...99).contains($0) }) else { return nil }
        let joined = groups.map(String.init).joined()
        return joined.count <= longestDigits ? Int(joined) : nil
    }

    private static func digits(_ run: [String]) -> Int? {
        guard run.count > 1, run.count <= longestDigits else { return nil }
        var joined = ""
        for said in run {
            switch Word(said) {
            case .unit(let unit)?: joined += String(unit)
            case .numeral(let numeral)? where numeral.count == 1: joined += numeral
            default: return nil
            }
        }
        return Int(joined)
    }
}
