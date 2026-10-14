#![no_main]

use libfuzzer_sys::fuzz_target;
use std::io::Cursor;

// Decodes the first frame into a buffer sized from the header, without calling
// `Info::raw_bytes`, so an IHDR whose frame size overflows `usize` reaches `Reader::next_frame`.
fuzz_target!(|data: &[u8]| {
    let limits = png::Limits { bytes: 1 << 16 };
    let decoder = png::Decoder::new_with_limits(Cursor::new(data), limits);
    let mut reader = match decoder.read_info() {
        Ok(reader) => reader,
        Err(_) => return,
    };

    let (width, height) = reader.info().size();
    let need = reader.output_line_size(width) as u128 * height as u128;
    let mut buf = vec![0u8; if need <= 1 << 20 { need as usize } else { 1 }];
    let _ = reader.next_frame(&mut buf);
});
