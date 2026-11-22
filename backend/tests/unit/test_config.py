import pytest
from pydantic import ValidationError

from hagig.config import (
    MAX_CONFIG_BYTES,
    Config,
    ConfigError,
    ConfigIssue,
    load_config,
)

SENTINEL = "SENTINEL-Ghostty"
MODEL = '[model]\nid = "qwen3-asr-0.6b"\n'


def write(tmp_path, text):
    # model.id is required; tests about other fields get a valid one appended.
    if "[model]" not in text:
        text += "\n" + MODEL
    path = tmp_path / "config.toml"
    path.write_text(text, encoding="utf-8")
    return path


def load(tmp_path, text, *, apple_silicon=False):
    return load_config(write(tmp_path, text), apple_silicon=apple_silicon)


def issues(tmp_path, text, *, apple_silicon=False):
    with pytest.raises(ConfigError) as error:
        load(tmp_path, text, apple_silicon=apple_silicon)
    assert error.value.code == "config_invalid"
    return [(issue.field, issue.code) for issue in error.value.issues]


# Defaults and valid files


@pytest.mark.parametrize(
    "text",
    [None, "", '[editor]\nmode = "vim"\n', "[model]\n", "[model]\n[editor]\n"],
    ids=["missing file", "empty file", "no model table", "empty model", "no id"],
)
def test_model_id_is_required(tmp_path, text):
    path = tmp_path / "config.toml"
    if text is not None:
        path.write_text(text, encoding="utf-8")
    with pytest.raises(ConfigError) as error:
        load_config(path, apple_silicon=False)
    assert error.value.code == "config_invalid"
    assert error.value.issues == (ConfigIssue("model.id", "missing"),)


def test_other_fields_default_when_only_model_id_is_set(tmp_path):
    config = load(tmp_path, MODEL)
    assert config.model.id == "qwen3-asr-0.6b"
    assert config.editor.mode == "standard"
    assert config.inference.network_isolation == "required"
    assert config.vocabulary.terms == []
    assert config.shortcuts.record == "ctrl+option+space"
    assert config.shortcuts.cancel == "ctrl+option+escape"
    assert config.shortcuts.copy_all == "cmd+shift+c"
    assert config.shortcuts.dismiss == "cmd+shift+d"
    empty_tables = "[editor]\n[inference]\n[vocabulary]\n[shortcuts]\n"
    assert load(tmp_path, empty_tables + MODEL) == config


def test_full_valid_file(tmp_path):
    config = load(
        tmp_path,
        """
        [editor]
        mode = "vim"
        [model]
        id = "qwen3-asr-1.7b"
        [inference]
        network_isolation = "disabled"
        [vocabulary]
        terms = ["Hagig", "  Ghostty ", "Qwen", "Amp"]
        """,
    )
    assert config.editor.mode == "vim"
    assert config.model.id == "qwen3-asr-1.7b"
    assert config.inference.network_isolation == "disabled"
    assert config.vocabulary.terms == ["Hagig", "Ghostty", "Qwen", "Amp"]


def test_whisper_is_accepted_on_apple_silicon(tmp_path):
    text = '[model]\nid = "whisper-large-v3-turbo"\n'
    assert load(tmp_path, text, apple_silicon=True).model.id == "whisper-large-v3-turbo"


def test_whisper_is_rejected_elsewhere(tmp_path):
    text = '[model]\nid = "whisper-large-v3-turbo"\n'
    assert issues(tmp_path, text) == [("model.id", "model_unsupported_on_platform")]


def test_whisper_fails_closed_without_a_platform_context():
    with pytest.raises(ValidationError):
        Config.model_validate({"model": {"id": "whisper-large-v3-turbo"}})


def test_environment_does_not_override_the_file(tmp_path, monkeypatch):
    for name in ("HAGIG_NETWORK_ISOLATION", "HAGIG_INFERENCE__NETWORK_ISOLATION"):
        monkeypatch.setenv(name, "disabled")
    monkeypatch.setenv("HAGIG_MODEL_ID", "qwen3-asr-1.7b")
    config = load(tmp_path, MODEL)
    assert config.inference.network_isolation == "required"
    assert config.model.id == "qwen3-asr-0.6b"


# Rejections name the field and a stable code


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ('[editor]\nmode = "emacs"\n', [("editor.mode", "invalid_value")]),
        ('[editor]\nmode = "Vim"\n', [("editor.mode", "invalid_value")]),
        ("[editor]\nmode = 1\n", [("editor.mode", "invalid_type")]),
        ('[model]\nid = "parakeet"\n', [("model.id", "invalid_value")]),
        ('[model]\nid = "Qwen/Qwen3-ASR-0.6B-hf"\n', [("model.id", "invalid_value")]),
        (
            '[inference]\nnetwork_isolation = "auto"\n',
            [("inference.network_isolation", "invalid_value")],
        ),
        (
            '[inference]\nnetwork_isolation = "Required"\n',
            [("inference.network_isolation", "invalid_value")],
        ),
        (
            "[inference]\nnetwork_isolation = false\n",
            [("inference.network_isolation", "invalid_type")],
        ),
        ('editor = "vim"\n', [("editor", "invalid_type")]),
        ('[vocabulary]\nterms = "Hagig"\n', [("vocabulary.terms", "invalid_type")]),
        ("[vocabulary]\nterms = [1]\n", [("vocabulary.terms[0]", "invalid_type")]),
        ("[model]\nid = 2026-11-10\n", [("model.id", "invalid_type")]),
    ],
)
def test_invalid_values_and_types(tmp_path, text, expected):
    assert issues(tmp_path, text) == expected


def test_unknown_keys_name_the_containing_table_not_the_key(tmp_path):
    text = f"{SENTINEL} = 1\n[editor]\n{SENTINEL}x = 1\n[{SENTINEL}y]\na = 1\n"
    found = issues(tmp_path, text)
    assert sorted(found) == sorted(
        [
            ("<root>", "unknown_key"),
            ("editor", "unknown_key"),
            ("<root>", "unknown_key"),
        ]
    )


def test_pydantic_aliases_and_alternate_spellings_are_rejected(tmp_path):
    text = '[inference]\nnetworkIsolation = "disabled"\nisolation = "disabled"\n'
    assert issues(tmp_path, text) == [
        ("inference", "unknown_key"),
        ("inference", "unknown_key"),
    ]


def test_several_issues_are_reported_together(tmp_path):
    text = '[editor]\nmode = "x"\n[model]\nid = "y"\n'
    assert issues(tmp_path, text) == [
        ("editor.mode", "invalid_value"),
        ("model.id", "invalid_value"),
    ]


# Shortcuts


@pytest.mark.parametrize(
    "shortcut",
    [
        "ctrl+option+space",
        "space+option+ctrl",
        "cmd+shift+d",
        "shift+f12",
        "ctrl+option+cmd+shift+0",
        "option+escape",
        "ctrl+slash",
    ],
)
def test_valid_shortcuts(tmp_path, shortcut):
    others = (
        'cancel = "ctrl+option+tab"\ncopy = "ctrl+option+c"\ndismiss = "ctrl+option+d"'
    )
    text = f'[shortcuts]\nrecord = "{shortcut}"\n{others}\n'
    assert load(tmp_path, text).shortcuts.record == shortcut


def test_copy_and_dismiss_shortcuts_load_from_their_toml_keys(tmp_path):
    text = '[shortcuts]\ncopy = "option+return"\ndismiss = "ctrl+f5"\n'
    shortcuts = load(tmp_path, text).shortcuts
    assert (shortcuts.copy_all, shortcuts.dismiss) == ("option+return", "ctrl+f5")
    # The Python attribute name is not a key.
    assert issues(tmp_path, '[shortcuts]\ncopy_all = "ctrl+c"\n') == [
        ("shortcuts", "unknown_key")
    ]


@pytest.mark.parametrize(
    "shortcut",
    [
        "",
        "space",  # no modifier
        "ctrl",  # no key
        "ctrl+option",
        "ctrl+a+b",  # two keys
        "ctrl+ctrl+a",  # duplicate modifier
        "Ctrl+a",  # uppercase
        "ctrl+A",
        "ctrl + a",  # spaces
        "ctrl+",
        "+a",
        "ctrl++a",
        "control+a",  # not a modifier name
        "alt+a",
        "command+a",
        "fn+a",
        "ctrl+f13",
        "ctrl+enter",
        "ctrl+é",
        "ctrl+[",
    ],
)
def test_invalid_shortcuts_name_the_field(tmp_path, shortcut):
    text = f'[shortcuts]\nrecord = "{shortcut}"\n'
    assert issues(tmp_path, text) == [("shortcuts.record", "invalid_value")]
    for name in ("cancel", "copy", "dismiss"):
        text = f'[shortcuts]\n{name} = "{shortcut}"\n'
        assert issues(tmp_path, text) == [(f"shortcuts.{name}", "invalid_value")]


def test_record_and_cancel_must_differ_in_any_order(tmp_path):
    text = '[shortcuts]\nrecord = "ctrl+shift+r"\ncancel = "shift+ctrl+r"\n'
    assert issues(tmp_path, text) == [("shortcuts.cancel", "invalid_value")]
    # Changing only record to the default cancel collides too.
    text = '[shortcuts]\nrecord = "ctrl+option+escape"\n'
    assert issues(tmp_path, text) == [("shortcuts.cancel", "invalid_value")]


FIELDS = ("record", "cancel", "copy", "dismiss")


@pytest.mark.parametrize(
    ("earlier", "later"),
    [(a, b) for i, a in enumerate(FIELDS) for b in FIELDS[i + 1 :]],
)
def test_all_four_shortcuts_must_differ_naming_the_later_field(
    tmp_path, earlier, later
):
    # Every field set to its own distinct chord, then two made equal.
    chords = dict(zip(FIELDS, ["ctrl+1", "ctrl+2", "ctrl+3", "ctrl+4"], strict=True))
    chords[earlier] = "shift+cmd+k"
    chords[later] = "cmd+shift+k"
    text = "[shortcuts]\n" + "".join(f'{k} = "{v}"\n' for k, v in chords.items())
    assert issues(tmp_path, text) == [(f"shortcuts.{later}", "invalid_value")]


@pytest.mark.parametrize(
    ("name", "default_of"),
    [("record", "copy"), ("cancel", "dismiss"), ("copy", "dismiss")],
)
def test_a_shortcut_equal_to_a_later_default_names_that_default(
    tmp_path, name, default_of
):
    default = {"copy": "cmd+shift+c", "dismiss": "cmd+shift+d"}[default_of]
    text = f'[shortcuts]\n{name} = "{default}"\n'
    assert issues(tmp_path, text) == [(f"shortcuts.{default_of}", "invalid_value")]


def test_shortcut_types_and_unknown_keys(tmp_path):
    assert issues(tmp_path, "[shortcuts]\nrecord = 1\n") == [
        ("shortcuts.record", "invalid_type")
    ]
    assert issues(tmp_path, '[shortcuts]\ntoggle = "ctrl+t"\n') == [
        ("shortcuts", "unknown_key")
    ]


# Vocabulary bounds


def terms_toml(terms):
    return "[vocabulary]\nterms = [" + ", ".join(f'"{t}"' for t in terms) + "]\n"


@pytest.mark.parametrize("term", ["", "   ", "\\t"])
def test_blank_terms_are_rejected_after_stripping(tmp_path, term):
    text = terms_toml(["ok", term])
    assert issues(tmp_path, text) == [("vocabulary.terms[1]", "invalid_value")]


@pytest.mark.parametrize(
    "escape", ["\\n", "\\r", "\\u0000", "\\u007f", "\\u0085", "\\u2028"]
)
def test_control_characters_inside_terms_are_rejected(tmp_path, escape):
    text = terms_toml([f"a{escape}b"])
    assert issues(tmp_path, text) == [("vocabulary.terms[0]", "invalid_value")]


def test_term_length_limit_counts_characters_after_stripping(tmp_path):
    fits = "é" * 100
    config = load(tmp_path, terms_toml([f"  {fits}  "]))
    assert config.vocabulary.terms == [fits]
    assert issues(tmp_path, terms_toml(["é" * 101])) == [
        ("vocabulary.terms[0]", "too_long")
    ]


def test_at_most_200_terms(tmp_path):
    assert (
        len(load(tmp_path, terms_toml([f"t{i}" for i in range(200)])).vocabulary.terms)
        == 200
    )
    assert issues(tmp_path, terms_toml([f"t{i}" for i in range(201)])) == [
        ("vocabulary.terms", "too_many")
    ]


def test_total_utf8_size_limit(tmp_path):
    # 4-byte characters: 41 terms of 100 characters is 16,400 bytes (> 16 KiB),
    # while 40 such terms plus one 96-character term is exactly 16,384 bytes.
    wide = "\U0001f600" * 100
    exact = [wide] * 40 + ["\U0001f600" * 96]
    assert len(load(tmp_path, terms_toml(exact)).vocabulary.terms) == 41
    over = [wide] * 41
    assert issues(tmp_path, terms_toml(over)) == [("vocabulary.terms", "too_large")]


def test_size_limit_uses_stripped_terms(tmp_path):
    padded = ["  " + "\U0001f600" * 100 + "  "] * 40 + ["\U0001f600" * 96]
    assert len(load(tmp_path, terms_toml(padded)).vocabulary.terms) == 41


# File-level failures


def test_syntax_errors_have_a_fixed_code(tmp_path):
    with pytest.raises(ConfigError) as error:
        load(tmp_path, f'[editor\nmode = "{SENTINEL}"\n')
    assert error.value.code == "config_syntax"
    assert error.value.issues == ()


def test_deep_nesting_is_a_syntax_error_not_a_crash(tmp_path):
    with pytest.raises(ConfigError) as error:
        load(tmp_path, "x = " + "[" * 5000 + "]" * 5000 + "\n")
    assert error.value.code == "config_syntax"
    assert error.value.__context__ is None


def test_oversized_file_is_rejected_without_parsing(tmp_path):
    path = tmp_path / "config.toml"
    with path.open("wb") as handle:
        handle.write(b'[editor]\nmode = "vim"\n')
        handle.truncate(MAX_CONFIG_BYTES + 1)
    with pytest.raises(ConfigError) as error:
        load_config(path, apple_silicon=False)
    assert error.value.code == "config_too_large"


def test_invalid_utf8_is_a_syntax_error(tmp_path):
    path = tmp_path / "config.toml"
    path.write_bytes(b'[vocabulary]\nterms = ["\xff"]\n')
    with pytest.raises(ConfigError) as error:
        load_config(path, apple_silicon=False)
    assert error.value.code == "config_syntax"


def test_unreadable_file_has_a_fixed_code(tmp_path):
    with pytest.raises(ConfigError) as error:
        load_config(tmp_path, apple_silicon=False)  # a directory
    assert error.value.code == "config_unreadable"


# Errors never echo values or pydantic messages


@pytest.mark.parametrize(
    "text",
    [
        f'[editor]\nmode = "{SENTINEL}"\n',
        f'[model]\nid = "{SENTINEL}"\n',
        f'[inference]\nnetwork_isolation = "{SENTINEL}"\n',
        f'[vocabulary]\nterms = ["{SENTINEL}\\nx"]\n',
        f'[vocabulary]\nterms = ["{SENTINEL * 10}"]\n',
        f'[vocabulary]\nterms = {{ "{SENTINEL}" = 1 }}\n',
        f'{SENTINEL} = "{SENTINEL}"\n',
        f"[editor\n{SENTINEL}\n",
        f'[shortcuts]\nrecord = "ctrl+{SENTINEL}"\n',
        f'[shortcuts]\n{SENTINEL} = "ctrl+a"\n',
    ],
)
def test_errors_are_content_free(tmp_path, text):
    with pytest.raises(ConfigError) as error:
        load(tmp_path, text)
    rendered = str(error.value) + repr(error.value) + repr(error.value.issues)
    assert SENTINEL not in rendered
    assert "pydantic" not in rendered.lower()
    assert "input" not in rendered.lower()
    # Nothing content-bearing is chained for a traceback to print.
    assert error.value.__cause__ is None
    assert error.value.__context__ is None


def test_issue_rendering(tmp_path):
    with pytest.raises(ConfigError) as error:
        load(tmp_path, '[editor]\nmode = "x"\n')
    assert error.value.issues == (ConfigIssue("editor.mode", "invalid_value"),)
    assert str(error.value) == "config_invalid: editor.mode invalid_value"
