#!/usr/bin/env python3
"""Merge a new Sparkle appcast item into an existing cumulative appcast."""

import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE}


def merge_appcasts(existing_path, new_path, output_path, max_versions=10):
    ET.register_namespace("sparkle", SPARKLE)

    try:
        tree = ET.parse(existing_path)
        root = tree.getroot()
    except (FileNotFoundError, ET.ParseError):
        root = ET.Element("rss", {"version": "2.0"})
        ET.SubElement(ET.SubElement(root, "channel"), "title").text = "Turm"
        tree = ET.ElementTree(root)

    try:
        new_root = ET.parse(new_path).getroot()
    except ET.ParseError as e:
        print(f"Error: failed to parse new appcast: {e}", file=sys.stderr)
        return False

    new_item = new_root.find("channel/item")
    if new_item is None:
        print("Error: no item in new appcast", file=sys.stderr)
        return False

    version = new_item.find("sparkle:version", NS)
    if version is None:
        print("Error: no sparkle:version in new item", file=sys.stderr)
        return False

    channel = root.find("channel")
    if channel is None:
        print("Error: no channel in existing appcast", file=sys.stderr)
        return False

    for item in channel.findall("item"):
        old = item.find("sparkle:version", NS)
        if old is not None and old.text == version.text:
            channel.remove(item)
            break

    first = channel.find("item")
    if first is not None:
        channel.insert(list(channel).index(first), new_item)
    else:
        channel.append(new_item)

    for item in channel.findall("item")[max_versions:]:
        channel.remove(item)

    tree.write(output_path, encoding="utf-8", xml_declaration=True)
    return True


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <existing> <new> <output> [max_versions]", file=sys.stderr)
        sys.exit(1)

    try:
        limit = int(sys.argv[4]) if len(sys.argv) > 4 else 10
    except ValueError:
        print(f"Error: max_versions must be an integer, got '{sys.argv[4]}'", file=sys.stderr)
        sys.exit(1)

    if not merge_appcasts(sys.argv[1], sys.argv[2], sys.argv[3], limit):
        sys.exit(1)
