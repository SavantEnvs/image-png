#![no_main]

use libfuzzer_sys::{fuzz_target, Corpus};

// png 0.12 API, the same decode `png-afl` does: read the header, then one whole frame.
fuzz_target!(|data: &[u8]| -> Corpus {
    let decoder = png::Decoder::new(data);
    let (info, mut reader) = match decoder.read_info() {
        Ok(v) => v,
        Err(_) => return Corpus::Reject,
    };
    if info.buffer_size() > 5_000_000 {
        return Corpus::Reject;
    }
    let mut img_data = vec![0u8; info.buffer_size()];
    let _ = reader.next_frame(&mut img_data);
    Corpus::Keep
});
