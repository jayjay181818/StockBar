// The floor for a compiled Rust helper: a process that has started, written a
// line and waits for one on standard input. It uses the standard library only
// and has no HTTP client, so a real helper holds more than this.
// helper_layers.py sets it beside the Python helper's import layers.
use std::io::{self, BufRead, Write};

fn main() {
    let mut output = io::stdout();
    output.write_all(b"r\n").expect("standard output is open");
    output.flush().expect("standard output is open");
    let mut line = String::new();
    let _ = io::stdin().lock().read_line(&mut line);
}
