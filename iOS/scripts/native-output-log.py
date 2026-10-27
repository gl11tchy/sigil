"""Drain one synthetic TextKit stream; retain bounded evidence without a deadline."""

import os
import sys
from pathlib import Path

LIMIT = 2 * 1024 * 1024
MARKER_LIMIT = 64
LINE_LIMIT = 512


def capture(directory, stream):
    pending = b""
    oversized = False
    retained = 0
    markers = 0
    truncated = False
    with (directory / f"textkit-{stream}.log").open("xb", buffering=0) as log:
        phases = (directory / "textkit-phases.log").open("xb", buffering=0) if stream == "stdout" else None
        try:
            while chunk := os.read(0, 65536):
                kept = chunk[:max(0, LIMIT - retained)]
                log.write(kept)
                retained += len(kept)
                if len(kept) != len(chunk) and not truncated:
                    log.write(b"\n[SIGIL_TEXTKIT log truncated at 2097152 bytes; stream still drained]\n")
                    truncated = True
                # Keep short, fixed synthetic markers even after the raw log cap.
                if phases is not None:
                    for part in chunk.splitlines(keepends=True):
                        pending += part[:max(0, LINE_LIMIT + 1 - len(pending))]
                        oversized = oversized or len(pending) > LINE_LIMIT
                        if part.endswith(b"\n"):
                            if not oversized and pending.startswith(b"SIGIL_TEXTKIT ") and markers < MARKER_LIMIT:
                                phases.write(pending)
                                markers += 1
                            pending = b""
                            oversized = False
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
        finally:
            if phases is not None:
                phases.close()


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[2] not in ("stdout", "stderr"):
        raise SystemExit("usage: native-output-log.py GENERATED_ARTIFACT_DIRECTORY stdout|stderr")
    capture(Path(sys.argv[1]), sys.argv[2])
