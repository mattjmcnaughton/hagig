"""The two in-tree inference engines (TDD section 2), imported only by the worker.

`hagig.worker.ENGINES` imports exactly one of these modules, the one the `load`
message names. Neither is a plugin: the set is closed. The server, CLI and the
other engine never import them.
"""
