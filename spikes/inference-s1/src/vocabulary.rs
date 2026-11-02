//! Structural spike grammar only; this does not certify native BPE representability.

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

#[cfg(test)]
mod tests {
    use super::parse_vocabulary;

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
        // Acceptance here is syntax-only. Native unsupported-token handling is open.
        assert_eq!(
            parse_vocabulary("café\n🤖".as_bytes()),
            Ok("café/🤖".into())
        );
    }
}
