import hashlib
import importlib.metadata
import json
import os
import platform
import sys
from pathlib import Path

PINNED = "2.1.1"
HORIZON = 14
ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = ROOT / "data" / "fixture_series.json"
OUTPUT_PATH = ROOT / "data" / "reference_outputs.json"
TEMPORARY_PATH = ROOT / "data" / "reference_outputs.json.tmp"


def check_version():
    try:
        installed = importlib.metadata.version("statsforecast")
    except importlib.metadata.PackageNotFoundError:
        sys.exit(f"statsforecast {PINNED} is required and is not installed")
    if installed != PINNED:
        sys.exit(f"statsforecast {PINNED} is required, found {installed}")
    return installed


def reference_outputs(installed):
    import numpy as np
    from statsforecast.models import (
        TSB,
        CrostonClassic,
        CrostonSBA,
        Naive,
        SeasonalNaive,
        SimpleExponentialSmoothingOptimized,
    )

    fixture_bytes = FIXTURE_PATH.read_bytes()
    fixtures = {}
    for fixture in json.loads(fixture_bytes)["fixtures"]:
        name = fixture["name"]
        y = np.asarray(fixture["values"], dtype=np.float64)
        models = [
            (Naive, {}),
            (SeasonalNaive, {"season_length": fixture["season_length"]}),
            (SimpleExponentialSmoothingOptimized, {}),
            (CrostonClassic, {}),
            (CrostonSBA, {}),
            (TSB, {"alpha_d": 0.1, "alpha_p": 0.1}),
        ]
        results = {}
        for model_class, params in models:
            model_name = model_class.__name__
            model = model_class(**params)
            mean = model.forecast(y=y, h=HORIZON)["mean"]
            if not np.isfinite(mean).all():
                sys.exit(
                    f"{model_name} returned a non-finite forecast for fixture {name}"
                )
            result = {"params": params, "forecast": [float(value) for value in mean]}
            if model_class is SimpleExponentialSmoothingOptimized:
                result["alpha"] = float(model.fit(y).model_["alpha"])
            results[model_name] = result
        fixtures[name] = results

    return {
        "statsforecast_version": installed,
        "python_version": platform.python_version(),
        "numpy_version": np.__version__,
        "platform": {"system": platform.system(), "machine": platform.machine()},
        "fixture_file_sha256": hashlib.sha256(fixture_bytes).hexdigest(),
        "horizon": HORIZON,
        "dtype": y.dtype.name,
        "fixtures": fixtures,
    }


def write_outputs(outputs):
    text = json.dumps(outputs, indent=2, allow_nan=False) + "\n"
    try:
        TEMPORARY_PATH.write_text(text, encoding="utf-8")
        os.replace(TEMPORARY_PATH, OUTPUT_PATH)
    finally:
        TEMPORARY_PATH.unlink(missing_ok=True)


def main():
    installed = check_version()
    write_outputs(reference_outputs(installed))


if __name__ == "__main__":
    main()
