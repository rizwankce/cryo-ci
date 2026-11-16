import CryoCICLI

#if canImport(Glibc)
	import Glibc
#elseif canImport(Musl)
	import Musl
#elseif canImport(Darwin)
	import Darwin
#endif

exit(CryoCICLI.main(Array(CommandLine.arguments.dropFirst())))
