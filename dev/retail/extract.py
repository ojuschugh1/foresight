import hashlib
import http.client
import importlib.util
import io
import json
import os
import re
import sys
import urllib.request
import zipfile
from collections import Counter, defaultdict
from datetime import date, datetime
from pathlib import Path

URL = "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip"
COLUMNS = ("Invoice", "StockCode", "Quantity", "InvoiceDate")
START_DATE = date(2009, 12, 1)
END_DATE = date(2011, 12, 9)
PRODUCT_CODE = r"[0-9]{5}[A-Za-z]*"
ROOT = Path(__file__).resolve().parents[2]
OUTPUT_PATH = ROOT / "tmp" / "retail_intermediate.json"
TEMPORARY_PATH = ROOT / "tmp" / "retail_intermediate.json.tmp"


def stop(step, detail):
    sys.exit(f"{step} failed: {detail}")


def check_libraries():
    for name in ("pandas", "openpyxl"):
        if importlib.util.find_spec(name) is None:
            stop("checking the libraries", f"{name} is required and is not installed")


def download():
    try:
        with urllib.request.urlopen(URL, timeout=60) as response:
            return response.read()
    except (OSError, http.client.HTTPException) as error:
        stop("downloading the zip", error)


def unzip(archive):
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as files:
            names = [name for name in files.namelist() if name.endswith(".xlsx")]
            workbooks = [files.read(name) for name in names]
    except Exception as error:
        stop("unzipping", error)
    if len(workbooks) != 1:
        stop("unzipping", f"expected one xlsx file in the zip, found {names}")
    return workbooks[0]


def read_worksheets(workbook):
    import pandas as pd

    try:
        frames = pd.read_excel(
            io.BytesIO(workbook),
            sheet_name=None,
            header=None,
            dtype=object,
            na_filter=False,
            engine="openpyxl",
        )
    except Exception as error:
        stop("reading the worksheets", error)
    return {
        name: list(frame.itertuples(index=False, name=None))
        for name, frame in frames.items()
    }


def select_columns(worksheets):
    headers = {name: rows[0] if rows else () for name, rows in worksheets.items()}
    for name, header in headers.items():
        for column in COLUMNS:
            count = header.count(column)
            if count != 1:
                stop(
                    "checking the header rows",
                    f"worksheet {name} has {count} header cells named {column}",
                )
    if len(set(headers.values())) != 1:
        stop(
            "checking the header rows",
            f"the worksheets do not share one header row: {headers}",
        )
    header = next(iter(headers.values()))
    # Column names come from the header row, which differs from the UCI variable notes
    return {column: header.index(column) for column in COLUMNS}


def whole_number(cell):
    if isinstance(cell, float) and cell.is_integer():
        return int(cell)
    if isinstance(cell, int) and not isinstance(cell, bool):
        return cell
    return None


def cell_text(cell):
    if isinstance(cell, str):
        return cell
    number = whole_number(cell)
    return None if number is None else str(number)


def line_key(row):
    return tuple(None if cell == "" else cell for cell in row)


def read_lines(worksheets, positions):
    lines = {}
    for name, rows in worksheets.items():
        counter = Counter()
        for number, row in enumerate(rows[1:], start=2):
            stamp = row[positions["InvoiceDate"]]
            quantity = row[positions["Quantity"]]
            if not isinstance(stamp, datetime):
                stop(
                    "reading the lines",
                    f"worksheet {name} row {number} has invoice date {stamp!r}",
                )
            if START_DATE <= stamp.date() <= END_DATE:
                if whole_number(quantity) is None:
                    stop(
                        "reading the lines",
                        f"worksheet {name} row {number} has quantity {quantity!r}",
                    )
                counter[line_key(row)] += 1
        if not counter:
            stop(
                "reading the lines",
                f"worksheet {name} has no line dated {START_DATE} to {END_DATE}",
            )
        lines[name] = counter
    return lines


def count_lines(lines):
    counted = Counter()
    for counter in lines.values():
        counted |= counter
    read = sum(sum(counter.values()) for counter in lines.values())
    return counted, read - sum(counted.values())


def worksheet_report(lines, positions):
    report = []
    for name, counter in lines.items():
        days = [line[positions["InvoiceDate"]].date() for line in counter]
        report.append(
            {
                "first_date": min(days).isoformat(),
                "last_date": max(days).isoformat(),
                "lines": sum(counter.values()),
                "name": name,
            }
        )
    return report


def trading_calendar(lines, positions):
    days = {
        line[positions["InvoiceDate"]].date()
        for counter in lines.values()
        for line in counter
    }
    return [day.isoformat() for day in sorted(days)]


def drop_lines(counted, positions):
    kept = {}
    for line, count in counted.items():
        invoice = cell_text(line[positions["Invoice"]])
        code = cell_text(line[positions["StockCode"]])
        quantity = whole_number(line[positions["Quantity"]])
        cancelled = invoice is not None and invoice.startswith(("C", "c"))
        product = code is not None and re.fullmatch(PRODUCT_CODE, code) is not None
        if not cancelled and quantity > 0 and product:
            kept[line] = count
    return kept


def daily_sums(kept, positions):
    sums = defaultdict(Counter)
    for line, count in kept.items():
        code = cell_text(line[positions["StockCode"]])
        day = line[positions["InvoiceDate"]].date().isoformat()
        sums[code][day] += whole_number(line[positions["Quantity"]]) * count
    return sums


def write_intermediate(intermediate):
    text = json.dumps(intermediate, indent=2, sort_keys=True, allow_nan=False) + "\n"
    try:
        OUTPUT_PATH.parent.mkdir(exist_ok=True)
        TEMPORARY_PATH.write_text(text, encoding="utf-8")
        os.replace(TEMPORARY_PATH, OUTPUT_PATH)
    except OSError as error:
        stop("writing the intermediate file", error)
    finally:
        TEMPORARY_PATH.unlink(missing_ok=True)


def main():
    check_libraries()
    archive = download()
    workbook = unzip(archive)
    worksheets = read_worksheets(workbook)
    positions = select_columns(worksheets)
    lines = read_lines(worksheets, positions)
    counted, uncounted = count_lines(lines)
    source = {
        "uncounted_copies": uncounted,
        "worksheets": worksheet_report(lines, positions),
        "xlsx_sha256": hashlib.sha256(workbook).hexdigest(),
        "zip_sha256": hashlib.sha256(archive).hexdigest(),
    }
    calendar = trading_calendar(lines, positions)
    kept = drop_lines(counted, positions)
    sums = daily_sums(kept, positions)
    write_intermediate({"calendar": calendar, "daily_sums": sums, "source": source})


if __name__ == "__main__":
    main()
