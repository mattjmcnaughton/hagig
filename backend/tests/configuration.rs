use hagig::config::Config;
use hagig::launcher::NetworkIsolation;

#[test]
fn defaults_are_required_standard_unboosted_and_explicit_settings_are_preserved() {
    let config = Config::parse("").unwrap();
    assert_eq!(config.editor_mode(), "standard");
    assert_eq!(config.network_isolation(), NetworkIsolation::Required);
    assert_eq!(config.hotwords(), "");
    assert_eq!(config.model_id(), "parakeet-tdt-0.6b-v2-int8-v1");
    let config = Config::parse(
        r#"
[editor]
mode = "vim"
[model]
id = "parakeet-tdt-0.6b-v2"
[inference]
network_isolation = "disabled"
[vocabulary]
terms = ["Hagig", "café", "hello world", "Hagig"]
"#,
    )
    .unwrap();
    assert_eq!(config.editor_mode(), "vim");
    assert_eq!(config.network_isolation(), NetworkIsolation::Disabled);
    assert_eq!(config.hotwords(), "Hagig/café/hello world/Hagig");
    assert_eq!(config.model_id(), "parakeet-tdt-0.6b-v2-int8-v1");
}

#[test]
fn invalid_or_unknown_settings_fail_without_echoing_values() {
    for invalid in [
        "unknown = 'PRIVATE_CANARY'".to_owned(),
        "[editor]\nmode='PRIVATE_CANARY'".into(),
        "[editor]\nextra='PRIVATE_CANARY'".into(),
        "[model]\nid='PRIVATE_CANARY'".into(),
        "[inference]\nnetwork_isolation='PRIVATE_CANARY'".into(),
        "[inference]\nnetwork_isolation=false".into(),
        "[vocabulary]\nterms='PRIVATE_CANARY'".into(),
        "[vocabulary]\nterms=[2]".into(),
        "[vocabulary]\nterms=['']".into(),
        "[vocabulary]\nterms=[' hello']".into(),
        "[vocabulary]\nterms=['hello ']".into(),
        "[vocabulary]\nterms=['hello  world']".into(),
        "[vocabulary]\nterms=['hello/world']".into(),
        "[vocabulary]\nterms=['hello:1']".into(),
        "[vocabulary]\nterms=['hello\u{a0}world']".into(),
        "[vocabulary]\nterms=['hello\nworld']".into(),
        format!("[vocabulary]\nterms=['{}']", "é".repeat(65)),
        format!("[vocabulary]\nterms=[{}]", vec!["'a'"; 257].join(",")),
        "[editor]\nmode='vim'\nmode='standard'".into(),
        format!("#{}", "a".repeat(65_536)),
    ] {
        let error = Config::parse(&invalid)
            .err()
            .expect("invalid configuration");
        assert!(error.starts_with("configuration_invalid"));
        assert!(!error.contains("PRIVATE_CANARY"));
    }
    for term in ["é".repeat(64), "a".repeat(128)] {
        assert!(Config::parse(&format!("[vocabulary]\nterms=['{term}']")).is_ok());
    }
    assert!(
        Config::parse(&format!(
            "[vocabulary]\nterms=[{}]",
            vec!["'a'"; 256].join(",")
        ))
        .is_ok()
    );
}
