#!/usr/bin/env python3
"""Builds the sky map's star and constellation data for ScopeKit from downloaded source files.

Download into a folder of its own:
  https://cdsarc.cds.unistra.fr/ftp/V/50/catalog.gz                          -> bsc5.gz   (Yale Bright Star Catalogue, 5th ed.)
  https://www.pas.rochester.edu/~emamajek/WGSN/IAU-CSN.txt                   -> iau-csn.txt (IAU star names)
  https://raw.githubusercontent.com/ofrohn/d3-celestial/master/data/constellations.lines.json -> d3c-lines.json
  https://raw.githubusercontent.com/ofrohn/d3-celestial/master/data/constellations.json       -> d3c-names.json
then run (with -I, so nothing in the download folder is imported):
  python3 -I scripts/make-sky-data.py <download folder> Packages/ScopeKit/Sources/ScopeKit/Resources
"""
import csv
import gzip
import json
import re
import sys
from pathlib import Path

MAGNITUDE_LIMIT = 6.5
GREEK = {
    "Alp": "α", "Bet": "β", "Gam": "γ", "Del": "δ", "Eps": "ε", "Zet": "ζ", "Eta": "η", "The": "θ",
    "Iot": "ι", "Kap": "κ", "Lam": "λ", "Mu": "μ", "Nu": "ν", "Xi": "ξ", "Omi": "ο", "Pi": "π",
    "Rho": "ρ", "Sig": "σ", "Tau": "τ", "Ups": "υ", "Phi": "φ", "Chi": "χ", "Psi": "ψ", "Ome": "ω",
}
SUPERSCRIPT = str.maketrans("123456789", "¹²³⁴⁵⁶⁷⁸⁹")


def designation(field: str) -> str:
    """BSC name field (bytes 5-14): Flamsteed number, Bayer letter, its index, constellation."""
    flamsteed, bayer, index, constellation = field[0:3].strip(), field[3:6].strip(), field[6:7].strip(), field[7:10].strip()
    if not constellation:
        return ""
    if bayer in GREEK:
        return f"{GREEK[bayer]}{index.translate(SUPERSCRIPT)} {constellation}"
    if flamsteed:
        return f"{flamsteed} {constellation}"
    return ""


def star_names(path: Path) -> dict[int, str]:
    names = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        match = re.search(r"\bHR (\d+)\b", line)
        if match:
            names[int(match.group(1))] = line[0:18].strip()
    return names


def stars(catalog: Path, names: dict[int, str]) -> list[list]:
    rows = []
    with gzip.open(catalog, "rt", encoding="latin-1") as file:
        for line in file:
            line = line.rstrip("\n").ljust(110)
            ra, dec, vmag = line[75:83], line[83:90], line[102:107]
            if not ra.strip() or not dec.strip() or not vmag.strip():
                continue  # novae and other entries without a position or magnitude
            magnitude = float(vmag)
            if magnitude > MAGNITUDE_LIMIT:
                continue
            hr = int(line[0:4])
            ra_hours = int(ra[0:2]) + int(ra[2:4]) / 60 + float(ra[4:8]) / 3600
            sign = -1 if dec[0] == "-" else 1
            dec_degrees = sign * (int(dec[1:3]) + int(dec[3:5]) / 60 + int(dec[5:7]) / 3600)
            rows.append([hr, f"{ra_hours:.6f}", f"{dec_degrees:.5f}", f"{magnitude:.2f}", designation(line[4:14]), names.get(hr, "")])
    return rows


def constellations(lines_path: Path, names_path: Path) -> list[dict]:
    def hours(longitude: float) -> float:  # GeoJSON longitude (-180...180) to RA hours
        return round((longitude % 360) / 15, 5)

    labels = {f["id"]: f for f in json.loads(names_path.read_text())["features"]}
    result = []
    for feature in json.loads(lines_path.read_text())["features"]:
        label = labels.get(feature["id"])
        entry = next((e for e in result if e["id"] == feature["id"]), None)  # Serpens comes in two parts
        polylines = [[[hours(lon), round(lat, 4)] for lon, lat in line] for line in feature["geometry"]["coordinates"]]
        if entry:
            entry["lines"] += polylines
            continue
        lon, lat = label["geometry"]["coordinates"] if label else feature["geometry"]["coordinates"][0][0]
        result.append({"id": feature["id"], "name": label["properties"]["name"] if label else feature["id"],
                       "label": [hours(lon), round(lat, 4)], "lines": polylines})
    return result


def main() -> None:
    source, output = Path(sys.argv[1]), Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    rows = stars(source / "bsc5.gz", star_names(source / "iau-csn.txt"))
    with open(output / "stars.csv", "w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file, lineterminator="\n")
        writer.writerow(["hr", "ra_hours", "dec_degrees", "vmag", "designation", "name"])
        writer.writerows(rows)
    groups = constellations(source / "d3c-lines.json", source / "d3c-names.json")
    (output / "constellations.json").write_text(json.dumps(groups, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(rows)} stars to magnitude {MAGNITUDE_LIMIT}, {sum(1 for r in rows if r[5])} named; {len(groups)} constellations")


if __name__ == "__main__":
    main()
