#!/usr/bin/env python3
# Thin launcher for mlx-audio's Kokoro TTS CLI that repairs the espeak-ng data path. misaki (Kokoro's
# G2P) loads espeak-ng via espeakng_loader, whose bundled wheel hard-codes a CI build path that does
# not exist on disk — so synthesis crashes with "phontab: No such file or directory". We point the
# loader at a real espeak-ng install (Homebrew by default; override with ESPEAK_LIBRARY /
# ESPEAK_DATA_PATH) before importing it, then hand off to the normal CLI. Args pass straight through:
#   python kokoro_launch.py --model <repo> --text "..." --voice af_heart --file_prefix out
import os, runpy, sys


def _fix_espeak() -> None:
    try:
        import espeakng_loader
    except ImportError:
        return
    lib = os.environ.get("ESPEAK_LIBRARY")
    data = os.environ.get("ESPEAK_DATA_PATH")
    if not (lib and data):
        for prefix in ("/opt/homebrew", "/usr/local"):
            cand_lib = os.path.join(prefix, "lib", "libespeak-ng.dylib")
            cand_data = os.path.join(prefix, "share", "espeak-ng-data")
            if os.path.exists(cand_lib) and os.path.exists(cand_data):
                lib, data = cand_lib, cand_data
                break
    if lib and data:
        espeakng_loader.get_library_path = lambda: lib
        espeakng_loader.get_data_path = lambda: data


_fix_espeak()
sys.argv = ["gen"] + sys.argv[1:]
runpy.run_module("mlx_audio.tts.generate", run_name="__main__")
