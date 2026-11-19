import Foundation

struct Query: Decodable {
    let root: String
    let candidates: [String]
    let expected: String
}

let query = try JSONDecoder().decode(Query.self, from: FileHandle.standardInput.readDataToEndOfFile())
let labels = GraftAccountLabel.assigned(in: URL(fileURLWithPath: query.root), ids: Set(query.candidates))
let answer: [Bool?] = query.candidates.map { id in
    labels[id].map { $0.caseInsensitiveCompare(query.expected) == .orderedSame }
}
FileHandle.standardOutput.write(try JSONEncoder().encode(answer))
