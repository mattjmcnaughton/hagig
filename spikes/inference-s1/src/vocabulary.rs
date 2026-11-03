//! Spike grammar and a checked singleton-closure preflight, not a BPE tokenizer.
use std::{collections::HashSet, fs::File, io::Read, path::Path};

const MAX_TABLE_BYTES: usize = 131_072;

pub fn parse_vocabulary(input: &[u8]) -> Result<String, &'static str> {
    let text = std::str::from_utf8(input).map_err(|_| "vocabulary_invalid")?;
    let mut terms = Vec::new();
    for line in text.split_inclusive('\n') {
        let term = line
            .strip_suffix("\r\n")
            .or_else(|| line.strip_suffix('\n'))
            .unwrap_or(line);
        if terms.len() == 256
            || term.is_empty()
            || term.len() > 128
            || term.split(' ').any(str::is_empty)
            || term
                .chars()
                .any(|c| c == '/' || c == ':' || c.is_control() || (c.is_whitespace() && c != ' '))
        {
            return Err("vocabulary_invalid");
        }
        terms.push(term);
    }
    Ok(terms.join("/"))
}

/// Call after structural parsing and model-file presence checks, before native
/// recognizer construction. Empty vocabulary is still unboosted, but the tables
/// must be valid. Native code reopens these paths: this does not prevent concurrent
/// replacement or attest that the native binary implements the inspected source.
pub fn validate_model_vocabulary(model: &Path, hotwords: &str) -> Result<(), &'static str> {
    let bpe = read_table(&model.join("bpe.vocab"))?;
    let tokens = read_table(&model.join("tokens.txt"))?;
    validate_tokenizer(hotwords, &bpe, &tokens)
}

fn read_table(path: &Path) -> Result<Vec<u8>, &'static str> {
    let mut bytes = Vec::new();
    File::open(path)
        .and_then(|file| {
            file.take((MAX_TABLE_BYTES + 1) as u64)
                .read_to_end(&mut bytes)
        })
        .map_err(|_| "model_invalid")?;
    if bytes.len() > MAX_TABLE_BYTES {
        return Err("model_invalid");
    }
    Ok(bytes)
}

fn table_rows(bytes: &[u8]) -> Result<Vec<(&str, &str)>, &'static str> {
    let invalid = "model_invalid";
    if bytes.len() > MAX_TABLE_BYTES {
        return Err(invalid);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| invalid)?;
    text.lines()
        .map(|line| {
            let mut fields = line.split_ascii_whitespace();
            let piece = fields.next().ok_or(invalid)?;
            let value = fields.next().ok_or(invalid)?;
            if fields.next().is_some() || piece.chars().any(|c| c.is_whitespace() || c.is_control())
            {
                return Err(invalid);
            }
            Ok((piece, value))
        })
        .collect()
}

fn validate_tokenizer(hotwords: &str, bpe: &[u8], tokens: &[u8]) -> Result<(), &'static str> {
    let invalid = "model_invalid";
    let bpe = table_rows(bpe)?;
    let tokens = table_rows(tokens)?;
    // This is the pinned candidate's correspondence, not arbitrary tokenizer
    // support: unknown at zero, BPE prefix identical, sole extra token is blank.
    if bpe.first().map(|row| row.0) != Some("<unk>")
        || tokens.len() != bpe.len() + 1
        || tokens.last().map(|row| row.0) != Some("<blk>")
    {
        return Err(invalid);
    }
    let mut pieces = HashSet::new();
    let mut singletons = HashSet::new();
    for (i, &(piece, score)) in bpe.iter().enumerate() {
        // The pinned scores are integer ranks. Require decimal i32 rather than
        // accepting Rust-only float spellings or underflow that native iostream
        // parsing could reject. Even 131 * i32::MAX is safely finite as f32.
        score.parse::<i32>().map_err(|_| invalid)?;
        if !pieces.insert(piece) || piece == "<blk>" || piece == "<0x00>" || tokens[i].0 != piece {
            return Err(invalid);
        }
        let mut chars = piece.chars();
        let first = chars.next().ok_or(invalid)?;
        if chars.next().is_none() {
            singletons.insert(first);
        }
    }
    for (i, &(_, id)) in tokens.iter().enumerate() {
        // Canonical decimal indices: no duplicate, signed, overflowing or
        // nonnumeric IDs, and no unknown/ordinary piece can map to blank.
        if id != i.to_string() {
            return Err(invalid);
        }
    }
    if !singletons.contains(&'▁')
        || "<unk>".chars().all(|c| singletons.contains(&c))
        || bpe[1..]
            .iter()
            .any(|(piece, _)| piece.chars().any(|c| !singletons.contains(&c)))
    {
        return Err(invalid);
    }
    // simple-sentencepiece 0.7 prefixes each word with ▁, with no case folding
    // or Unicode normalization. Closure gives a known singleton at EVERY scalar
    // boundary; scored selection cannot reach a gap. Conversely, no ordinary
    // piece can cover a scalar outside this set. Thus no DP/tokenizer replica is
    // needed. Exclude unknown even when its literal spelling matches a piece.
    if hotwords
        .split(['/', ' '])
        .any(|word| word.chars().any(|c| !singletons.contains(&c)))
    {
        return Err("vocabulary_invalid");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{parse_vocabulary, validate_tokenizer};

    const BPE: &str = "<unk>\t0\n▁\t-1\na\t-2\nb\t-3\né\t-4\nΩ\t-5\n▁ab\t-6\n";
    const TOKENS: &str = "<unk> 0\n▁ 1\na 2\nb 3\né 4\nΩ 5\n▁ab 6\n<blk> 7\n";

    #[test]
    fn singleton_closed_vocabulary_is_exact_not_ascii_or_normalized() {
        for term in ["", "ab", "é", "Ω", "ab é", "ab/Ω", "▁", "ab/ab"] {
            assert_eq!(
                validate_tokenizer(term, BPE.as_bytes(), TOKENS.as_bytes()),
                Ok(())
            );
        }
        for term in ["🤖", "ab🤖", "ab/🤖", "e\u{301}", "<unk>", "<blk>", "中"] {
            assert_eq!(
                validate_tokenizer(term, BPE.as_bytes(), TOKENS.as_bytes()),
                Err("vocabulary_invalid")
            );
        }
    }

    #[test]
    fn invalid_table_assumptions_fail_closed_even_for_empty_vocabulary() {
        let cases = [
            (String::new(), TOKENS.into()),
            (BPE.into(), String::new()),
            (BPE.replace("▁\t-1\n", ""), TOKENS.into()),
            (BPE.replace("a\t-2", "a\tNaN"), TOKENS.into()),
            (BPE.replace("a\t-2", "a\tinf"), TOKENS.into()),
            (BPE.replace("a\t-2", "a\t3e38"), TOKENS.into()),
            (BPE.replace("a\t-2", "a\t1e-100"), TOKENS.into()),
            (BPE.replace("a\t-2", "a\t2147483648"), TOKENS.into()),
            (BPE.replace("a\t-2", "a\t-2147483649"), TOKENS.into()),
            (BPE.replace("a\t-2", "a\t-2 extra"), TOKENS.into()),
            (format!("{BPE}\n"), TOKENS.into()),
            (BPE.replace("a\t-2", "é\t-2"), TOKENS.into()),
            (BPE.into(), TOKENS.replace("a 2", "a 1")),
            (BPE.into(), TOKENS.replace("a 2", "a 2 extra")),
            (BPE.into(), TOKENS.replace("a 2", "c 2")),
            (BPE.into(), TOKENS.replace("<blk> 7", "<blk> 0")),
            (BPE.into(), format!("{TOKENS}extra 8\n")),
            (BPE.replace("a\t-2", "a\0\t-2"), TOKENS.into()),
            (BPE.replace("a\t-2", "a\u{a0}-2"), TOKENS.into()),
        ];
        for (bpe, tokens) in cases {
            assert_eq!(
                validate_tokenizer("", bpe.as_bytes(), tokens.as_bytes()),
                Err("model_invalid")
            );
        }
        assert_eq!(
            validate_tokenizer("", &[0xff], TOKENS.as_bytes()),
            Err("model_invalid")
        );
        assert_eq!(
            validate_tokenizer("", BPE.as_bytes(), &[0xff]),
            Err("model_invalid")
        );
    }

    #[test]
    fn closure_and_reserved_pieces_are_checked_not_just_character_presence() {
        // Fully corresponding tables, but 'x' has no singleton: a generic
        // character-union or exists-a-segmentation approximation is not enough.
        for (bpe, tokens) in [
            (
                "<unk>\t0\n▁\t-1\na\t-2\nax\t-3\n",
                "<unk> 0\n▁ 1\na 2\nax 3\n<blk> 4\n",
            ),
            ("<unk>\t0\na\t-1\n", "<unk> 0\na 1\n<blk> 2\n"),
            (
                "<unk>\t0\n▁\t-1\n<0x00>\t-2\n",
                "<unk> 0\n▁ 1\n<0x00> 2\n<blk> 3\n",
            ),
            (
                "<unk>\t0\n▁\t-1\n<\t-2\n>\t-3\nu\t-4\nn\t-5\nk\t-6\n",
                "<unk> 0\n▁ 1\n< 2\n> 3\nu 4\nn 5\nk 6\n<blk> 7\n",
            ),
        ] {
            assert_eq!(
                validate_tokenizer("", bpe.as_bytes(), tokens.as_bytes()),
                Err("model_invalid")
            );
        }
    }

    #[test]
    fn table_byte_limits_precede_parsing() {
        let bpe = format!("{}{BPE}", " ".repeat(super::MAX_TABLE_BYTES - BPE.len()));
        let tokens = format!(
            "{}{TOKENS}",
            " ".repeat(super::MAX_TABLE_BYTES - TOKENS.len())
        );
        assert_eq!(
            validate_tokenizer("é", bpe.as_bytes(), tokens.as_bytes()),
            Ok(())
        );
        assert_eq!(
            validate_tokenizer("", format!(" {bpe}").as_bytes(), TOKENS.as_bytes()),
            Err("model_invalid")
        );
        assert_eq!(
            validate_tokenizer("", BPE.as_bytes(), format!(" {tokens}").as_bytes()),
            Err("model_invalid")
        );
    }

    #[test]
    fn valid_terms_keep_spelling_and_order() {
        assert_eq!(
            parse_vocabulary(b"Hagig\nsherpa-onnx\nhello world\n"),
            Ok("Hagig/sherpa-onnx/hello world".into())
        );
        assert_eq!(
            parse_vocabulary(b"Hagig\r\nGhostty\r\n"),
            Ok("Hagig/Ghostty".into())
        );
        assert_eq!(parse_vocabulary(b"Hagig\nHagig"), Ok("Hagig/Hagig".into()));
    }

    #[test]
    fn empty_file_is_explicit_unboosted_control() {
        assert_eq!(parse_vocabulary(b""), Ok(String::new()));
    }

    #[test]
    fn malformed_entries_are_rejected_not_normalized_or_native_skipped() {
        for input in [
            "\n",
            "Hagig\n\n",
            "\nHagig",
            " Hagig",
            "Hagig ",
            "hello  world",
            "hello\tworld",
            "hello\rworld",
            "a\0b",
            "hello/world",
            "hello :1 trailing",
            "hello:1",
            "\u{7f}",
            "hello\u{a0}world",
            "hello\u{85}world",
        ] {
            assert_eq!(
                parse_vocabulary(input.as_bytes()),
                Err("vocabulary_invalid"),
                "malformed entry must fail"
            );
        }
        assert_eq!(parse_vocabulary(&[0xff]), Err("vocabulary_invalid"));
    }

    #[test]
    fn limits_count_utf8_bytes_and_terms() {
        assert!(parse_vocabulary("a".repeat(128).as_bytes()).is_ok());
        assert_eq!(
            parse_vocabulary("a".repeat(129).as_bytes()),
            Err("vocabulary_invalid")
        );
        assert!(parse_vocabulary("é".repeat(64).as_bytes()).is_ok());
        assert_eq!(
            parse_vocabulary("é".repeat(65).as_bytes()),
            Err("vocabulary_invalid")
        );
        assert!(parse_vocabulary(vec!["a"; 256].join("\n").as_bytes()).is_ok());
        assert_eq!(
            parse_vocabulary(vec!["a"; 257].join("\n").as_bytes()),
            Err("vocabulary_invalid")
        );
    }

    #[test]
    fn nonwhitespace_unicode_is_not_a_tokenization_guarantee() {
        // Acceptance here is syntax-only; model-aware preflight is separate.
        assert_eq!(
            parse_vocabulary("café\n🤖".as_bytes()),
            Ok("café/🤖".into())
        );
    }
}
