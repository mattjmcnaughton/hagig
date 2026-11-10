import struct

import pytest

from hagig.framing import ProtocolError, decode_message, parse_header

RESULT = frozenset({"result", "error"})


def decode(text, expected=RESULT):
    return decode_message(text.encode(), expected=expected)


def test_accepts_exact_messages():
    assert (
        decode('{"type":"result","generation":3,"request_id":"a-B_9","text":"x"}')[
            "text"
        ]
        == "x"
    )
    assert (
        decode(
            '{"type":"error","generation":1,"request_id":null,"code":"model_missing"}'
        )["request_id"]
        is None
    )


@pytest.mark.parametrize(
    "text",
    [
        '{"type":"result","generation":1,"request_id":"a","text":"x","extra":1}',
        '{"type":"result","generation":1,"request_id":"a"}',
        '{"type":"result","generation":1.0,"request_id":"a","text":"x"}',
        '{"type":"result","generation":true,"request_id":"a","text":"x"}',
        '{"type":"result","generation":0,"request_id":"a","text":"x"}',
        '{"type":"result","generation":1,"request_id":"a/b","text":"x"}',
        '{"type":"result","generation":1,"request_id":"","text":"x"}',
        '{"type":"result","generation":1,"request_id":"a","text":["x"]}',
        '{"type":"result","generation":1,"request_id":"a","text":"\\ud800"}',
        '{"type":"result","generation":1,"request_id":"a","text":"x","text":"y"}',
        '{"type":"result","generation":NaN,"request_id":"a","text":"x"}',
        '{"type":"loaded","generation":1}',
        '{"type":"other","generation":1}',
        '["result"]',
        '{"type":"error","generation":1,"request_id":"a","code":7}',
    ],
)
def test_rejects_anything_but_the_expected_shape(text):
    with pytest.raises(ProtocolError):
        decode(text)


def test_request_id_length_bounds():
    ok = '{"type":"result","generation":1,"request_id":"%s","text":""}'
    assert decode(ok % ("a" * 128))
    with pytest.raises(ProtocolError):
        decode(ok % ("a" * 129))


@pytest.mark.parametrize(
    ("kind", "length", "valid"),
    [
        (1, 1, True),
        (1, 65_536, True),
        (1, 0, False),
        (1, 65_537, False),
        (2, 4, True),
        (2, 19_200_000, True),
        (2, 19_200_004, False),
        (2, 6, False),
        (2, 0, False),
        (0, 4, False),
        (3, 4, False),
    ],
)
def test_header_validated_before_payload(kind, length, valid):
    header = struct.pack(">BI", kind, length)
    if valid:
        assert parse_header(header, allowed=frozenset({1, 2})) == (kind, length)
    else:
        with pytest.raises(ProtocolError):
            parse_header(header, allowed=frozenset({1, 2}))


def test_header_kind_must_be_allowed_in_this_direction():
    with pytest.raises(ProtocolError):
        parse_header(struct.pack(">BI", 2, 4), allowed=frozenset({1}))


@pytest.mark.parametrize("depth", [500, 3_000, 30_000])
def test_deep_nesting_from_a_worker_is_a_protocol_error(depth):
    # A compromised worker must not escape the content-free ProtocolError path.
    nested = "[" * depth + "]" * depth
    text = '{"type":"result","generation":1,"request_id":"a","text":' + nested + "}"
    assert len(text) <= 65_536
    with pytest.raises(ProtocolError):
        decode(text)
