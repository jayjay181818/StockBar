import Foundation

// The floor for a compiled Swift helper: a process that has a URLSession and a
// JSON decoder ready and waits for a line on standard input. It makes no
// request. helper_layers.py sets it beside the Python helper's import layers.
let session = URLSession(configuration: .ephemeral)
let decoder = JSONDecoder()
_ = try? decoder.decode([String: Double].self, from: Data("{\"price\": 1.0}".utf8))
FileHandle.standardOutput.write(Data("r\n".utf8))
_ = readLine()
session.invalidateAndCancel()
