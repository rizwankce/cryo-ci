/// A tiny argument parser: `--x value`, `--x=value`, booleans, positionals, `-h/--help`.
struct ArgSpec {
	var values: Set<String> = []
	var bools: Set<String> = []
	/// Stop flag parsing at the first positional (the rest are passed through), e.g. `cryo ssh L1 ls -l`.
	var stopAtPositional = false
}

struct ParsedArgs {
	var values: [String: String] = [:]
	/// Every occurrence of a value option, in order (for repeatable ones like `--repo`).
	var all: [String: [String]] = [:]
	var bools: Set<String> = []
	var positionals: [String] = []
	var help = false

	func flag(_ name: String) -> Bool { bools.contains(name) }
}

struct UsageError: Error { let message: String }

func parseArgs(_ args: [String], _ spec: ArgSpec) throws -> ParsedArgs {
	var out = ParsedArgs()
	var i = 0
	var onlyPositional = false
	while i < args.count {
		let a = args[i]
		i += 1
		if onlyPositional || a == "-" || !a.hasPrefix("-") {
			out.positionals.append(a)
			if spec.stopAtPositional {
				out.positionals.append(contentsOf: args[i...])
				break
			}
			continue
		}
		if a == "--" {
			onlyPositional = true
			continue
		}
		if a == "-h" || a == "--help" {
			out.help = true
			continue
		}
		guard a.hasPrefix("--") else { throw UsageError(message: "unknown option \(a)") }
		var name = String(a.dropFirst(2))
		var inline: String?
		if let eq = name.firstIndex(of: "=") {
			inline = String(name[name.index(after: eq)...])
			name = String(name[..<eq])
		}
		if spec.values.contains(name) {
			let value: String
			if let inline {
				value = inline
			} else {
				guard i < args.count else { throw UsageError(message: "--\(name) needs a value") }
				value = args[i]
				i += 1
			}
			out.values[name] = value
			out.all[name, default: []].append(value)
		} else if spec.bools.contains(name) {
			if let inline {
				switch inline {
				case "true", "1", "yes": out.bools.insert(name)
				case "false", "0", "no": out.bools.remove(name)
				default: throw UsageError(message: "--\(name) takes no value")
				}
			} else {
				out.bools.insert(name)
			}
		} else {
			throw UsageError(message: "unknown option --\(name)")
		}
	}
	return out
}
