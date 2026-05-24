import Foundation

func fatalCoderNotImplemented(
    file: StaticString = #file,
    line: UInt = #line
) -> Never {
    fatalError("init(coder:) has not been implemented — this view is created programmatically", file: file, line: line)
}
