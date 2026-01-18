"""Download the sky130 PDK exactly as LibreLane does, but tolerant of slow links.

LibreLane fetches the PDK on first run through Ciel, whose HTTP client uses
httpx's default 5 s read timeout. On slow connections that fails with
`httpx.ReadTimeout`. This script makes the same `ciel.fetch(...)` call
(same open_pdks revision, same data source, same library set) with a 600 s
timeout and retries.

Run inside the LibreLane nix-shell:
    nix-shell ~/librelane/shell.nix --run "python3 scripts/fetch_pdk.py"
"""
import time

import httpx

_orig_init = httpx.Client.__init__


def _init(self, *args, **kwargs):
    kwargs["timeout"] = httpx.Timeout(600.0, connect=60.0)
    _orig_init(self, *args, **kwargs)


httpx.Client.__init__ = _init

import ciel  # noqa: E402  (must come after the patch)
from ciel.source import StaticWebDataSource  # noqa: E402
from librelane.common.misc import get_pdk_hash  # noqa: E402

rev = get_pdk_hash("sky130A")
home = ciel.get_ciel_home(None)
print("open_pdks revision:", rev)
for attempt in range(1, 9):
    try:
        version = ciel.fetch(
            home,
            "sky130",
            rev,
            data_source=StaticWebDataSource(
                "https://fossi-foundation.github.io/ciel-releases"
            ),
            include_libraries=["default"],
        )
        print("PDK ready:", version.get_dir(home))
        break
    except Exception as exc:  # retry on network errors
        print(f"attempt {attempt} failed: {type(exc).__name__}: {exc}")
        time.sleep(15)
else:
    raise SystemExit("PDK download failed after 8 attempts")
