"""Streaming upload validation (PROTOCOL.md, Canonical audio and upload validation)."""

import struct

import pytest

from hagig.services.requests import AudioValidator, RequestError

CAP = 19_200_000
NAN = struct.pack("<f", float("nan"))
ONE = struct.pack("<f", 1.0)


def outcome(*chunks):
    validator = AudioValidator()
    try:
        for chunk in chunks:
            validator.feed(chunk)
        return bytes(validator.finish())
    except RequestError as error:
        return (error.code, error.status)


def test_a_bad_sample_split_across_chunks_is_still_checked():
    assert outcome(NAN[:2], NAN[2:]) == ("invalid_audio", 400)
    assert outcome(ONE, NAN[:1], NAN[1:3], NAN[3:]) == ("invalid_audio", 400)


def test_samples_split_across_chunks_are_reassembled():
    data = struct.pack("<3f", 0.5, -1.0, 1.0)
    assert outcome(*(data[i : i + 1] for i in range(len(data)))) == data


@pytest.mark.parametrize(
    "chunks",
    [
        [NAN + bytes(CAP)],
        [bytes(CAP - 4), NAN + b"\x00"],
        [NAN, bytes(CAP)],
    ],
    ids=["same-chunk", "bad-last-sample-then-over", "separate-chunks"],
)
def test_a_bad_sample_before_the_cap_byte_wins_whatever_the_chunking(chunks):
    assert outcome(*chunks) == ("invalid_audio", 400)


def test_one_byte_over_the_cap_is_413_and_the_cap_itself_is_valid():
    assert outcome(bytes(CAP - 4), ONE + b"\x00") == ("invalid_audio", 413)
    assert len(outcome(bytes(CAP - 4), ONE)) == CAP
