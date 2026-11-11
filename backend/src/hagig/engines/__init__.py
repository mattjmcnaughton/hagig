"""The two in-tree inference engines (TDD section 2), imported only by the worker.

`hagig.worker.ENGINES` imports exactly one of these modules, the one the `load`
message names. Neither is a plugin: the set is closed. The server, CLI and the
other engine never import them. A load failure is
`hagig.models.ModelError("model_invalid")`, which the worker reports as is.
"""

from collections.abc import Sequence


def vocabulary_prompt(vocabulary: Sequence[str]) -> str | None:
    """The biasing prompt both engines use, or None with no vocabulary."""
    return f"Vocabulary: {', '.join(vocabulary)}." if vocabulary else None
