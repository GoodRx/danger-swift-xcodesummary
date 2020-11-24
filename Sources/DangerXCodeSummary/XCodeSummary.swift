import Foundation
import Danger

/// A filter that can be used to hide specific results based on certain conditions.
public typealias ResultsFilter = (Result) -> Bool

/// Danger-Swift plugin that adds build errors, warnings and unit tests results generated from xcodebuild to your Danger report
/// Requires xcpretty-json-formatter
public final class XCodeSummary {
    private enum WarningKeys: String {
        case warnings
        case ldWarning = "ld_warnings"
        case compileWarnings = "compile_warnings"
    }

    private enum ErrorKeys: String {
        case errors
        case compileErrors = "compile_errors"
        case fileMissing = "file_missing_errors"
        case undefinedSymbols = "undefined_symbols_errors"
        case duplicatedSymbols = "duplicate_symbols_errors"
        case testFailures = "tests_failures"
    }

    private enum MessageKeys: String {
        case testSummary = "tests_summary_messages"
    }

    lazy var warnings: [Result] = {
        let warningMessages: [String] = json[WarningKeys.warnings] ?? []
        let ldWarningMessages: [String] = json[WarningKeys.ldWarning] ?? []
        let compileWarnings: [[String:Any]] = json[WarningKeys.compileWarnings] ?? []

        return warningMessages.map { Result(message: $0, category: .warning) } +
            ldWarningMessages.map { Result(message: $0, category: .warning) } +
            compileWarnings.compactMap { try? CompilerMessageParser.parseMessage(messageJSON: $0, category: .warning) }
    }()

    /// Number of warnings generated during the build
    public var warningsCount: Int {
        return warnings.count
    }

    lazy var errors: [Result] = {
        let errors: [String] = json[ErrorKeys.errors] ?? []
        let compileErrors: [[String:Any]] = json[ErrorKeys.compileErrors] ?? []
        let missingFiles: [[String:Any]] = json[ErrorKeys.fileMissing] ?? []
        let undefinedSymbols: [[String:Any]] = json[ErrorKeys.undefinedSymbols] ?? []
        let duplicatedSymbols: [[String:Any]] = json[ErrorKeys.duplicatedSymbols] ?? []
        let failedTests: [String:[[String:Any]]] = json[ErrorKeys.testFailures] ?? [:]

        var result = errors.map { Result(message: $0, category: .error) }
        result += compileErrors.compactMap { try? CompilerMessageParser.parseMessage(messageJSON: $0, category: .error) }
        result += missingFiles.compactMap { MissingFileErrorParser.parseMissingFileError(missingFileErrorJSON: $0) }
        result += undefinedSymbols.map { SymbolsErrorsParser.parseUndefinedSymbols(json: $0) }
        result += duplicatedSymbols.map { SymbolsErrorsParser.parseDuplicatedSymbols(json: $0) }

        result += failedTests.flatMap { (key, value) in
            return value.compactMap {
                try? TestFailuresParser.parseTest(testJSON: $0, testSuite: key)
            }
        }

        return result
    }()

    /// Number of errors generated during the build
    public var errorsCount: Int {
        return errors.count
    }

    lazy var messages: [Result] = {
        let messages: [String] = json[MessageKeys.testSummary] ?? []
        return messages.map { Result(message: $0.trimmingCharacters(in: .whitespacesAndNewlines), category: .message) }
    }()

    private let json: [String:Any]
    private let dsl: DangerDSL
    private let resultsFilter: ResultsFilter?

    init(json: [String:Any], dsl: DangerDSL = Danger(), resultsFilter: ResultsFilter? = nil) {
        self.json = json
        self.dsl = dsl
        self.resultsFilter = resultsFilter
    }

    public convenience init(filePath: String, resultsFilter: ResultsFilter? = nil) {
        guard let content = try? String(contentsOfFile: filePath),
            let data = content.data(using: .utf8) else {
            fatalError("Report not found")
        }

        guard let any = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
            let json = any as? [String:Any] else {
            fatalError("Report file is not a valid json")
        }

        self.init(json: json, dsl: Danger(), resultsFilter: resultsFilter)
    }

    /// Shows all build errors, warnings and unit tests results generated from `xcodebuild` or `Swift Package Manager`
    public func report(_ reporter: ((Result) -> Void)? = nil) {
        let results = warnings + errors + messages
        results.filter(using: resultsFilter).removingDuplicates().forEach(reporter ?? reportResult)
    }

    func reportResult(_ result: Result) {
        switch result.category {
        case .warning:
            if let file = result.file, let line = result.line {
              dsl.warn(message: result.message, file: file, line: line)
            } else {
              dsl.warn(result.message)
            }
        case .error:
            if let file = result.file, let line = result.line {
                dsl.fail(message: result.message, file: file, line: line)
            } else {
                dsl.fail(result.message)
            }
        case .message:
          dsl.message(result.message)
        }
    }
}

extension Dictionary {
    subscript<T: RawRepresentable, R>(rawRappresentable: T) -> R? where T.RawValue == Key {
        return self[rawRappresentable.rawValue] as? R
    }
}

extension Array where Element == Result {
    func filter(using resultsFilter: ResultsFilter?) -> [Element] {
        guard let resultsFilter = resultsFilter else { return self }
        return self.filter(resultsFilter)
    }

    func removingDuplicates() -> [Element] {
        var addedDict = [Element: Bool]()

        return filter {
            addedDict.updateValue(true, forKey: $0) == nil
        }
    }
}
