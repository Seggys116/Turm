#!/usr/bin/env python3
"""Add sparkle:edSignature to appcast enclosures; exits 1 unless every one is signed."""

import os
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SIG = f"{{{SPARKLE}}}edSignature"


def sign(sign_update, private_key, path):
    result = subprocess.run(
        [sign_update, "-f", "-", "-p", path],
        input=private_key,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Error signing {path}: {result.stderr}", file=sys.stderr)
        return None
    return result.stdout.strip()


def add_signatures(sign_update, appcast_path, dmg_dir, private_key):
    ET.register_namespace("sparkle", SPARKLE)

    try:
        tree = ET.parse(appcast_path)
    except ET.ParseError as e:
        print(f"Error: failed to parse appcast: {e}", file=sys.stderr)
        return False

    enclosures = [e for e in tree.getroot().findall(".//item/enclosure") if e.get("url")]
    if not enclosures:
        print("Error: no enclosures in appcast", file=sys.stderr)
        return False

    failed = False
    for enclosure in enclosures:
        name = enclosure.get("url").rsplit("/", 1)[-1]
        path = os.path.join(dmg_dir, name)
        if not os.path.exists(path):
            print(f"Error: DMG not found: {path}", file=sys.stderr)
            failed = True
            continue
        signature = sign(sign_update, private_key, path)
        if not signature:
            print(f"Error: failed to sign {name}", file=sys.stderr)
            failed = True
            continue
        enclosure.set(SIG, signature)
        print(f"Signed {name}: {signature[:25]}...")

    if failed:
        return False

    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)

    for enclosure in ET.parse(appcast_path).getroot().findall(".//item/enclosure"):
        if not enclosure.get(SIG):
            print("Error: enclosure has no signature after write", file=sys.stderr)
            return False
    return True


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <bin-dir> <appcast.xml> <dmg-dir>", file=sys.stderr)
        print("The EdDSA private key is read from SPARKLE_PRIVATE_KEY.", file=sys.stderr)
        sys.exit(1)

    bin_dir, appcast, dmg_dir = sys.argv[1:4]
    sign_update = os.path.join(bin_dir, "sign_update")
    if not os.path.exists(sign_update):
        print(f"Error: sign_update not found at {sign_update}", file=sys.stderr)
        sys.exit(1)

    key = os.environ.get("SPARKLE_PRIVATE_KEY")
    if not key:
        print("Error: SPARKLE_PRIVATE_KEY is not set", file=sys.stderr)
        sys.exit(1)

    if not add_signatures(sign_update, appcast, dmg_dir, key):
        sys.exit(1)
