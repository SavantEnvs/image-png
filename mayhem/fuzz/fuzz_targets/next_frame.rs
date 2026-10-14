#![no_main]

use libfuzzer_sys::fuzz_target;
use std::io::Cursor;

// Decodes the first frame into a buffer sized from the header, without calling
// `Info::raw_bytes`. With `EXPAND`, the output color type is only known to be wider (a `tRNS`
// chunk turns an indexed Rgb output into Rgba) after `read_info` has checked the frame size, so a
// frame size that overflows `usize` can reach `Reader::next_frame`. The limit lets a row
// (reserved against it when the frame starts) be wide enough for `row * height` to overflow.
// `png` is built without overflow checks (see build.sh), so an unchecked size wraps.
fuzz_target!(|data: &[u8]| {
    let limits = png::Limits { bytes: 1 << 40 };
    let mut decoder = png::Decoder::new_with_limits(Cursor::new(data), limits);
    decoder.set_transformations(png::Transformations::EXPAND);
    let mut reader = match decoder.read_info() {
        Ok(reader) => reader,
        Err(_) => return,
    };

    let (width, height) = reader.info().size();
    let need = reader.output_line_size(width) as u128 * height as u128;
    let mut buf = vec![0u8; if need <= 1 << 20 { need as usize } else { 1 }];
    let _ = reader.next_frame(&mut buf);
});
