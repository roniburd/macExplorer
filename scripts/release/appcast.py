#!/usr/bin/env python3
"""Insert one signed Sparkle item into appcast.xml (distribution spec §5 step 5). Stdlib only; run with python3 -I."""
import argparse, os, sys, tempfile
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
S = "{%s}" % SPARKLE


def parse_args(argv):
    p = argparse.ArgumentParser()
    for name in ("appcast", "version", "build", "url", "length", "ed-signature", "min-os", "notes-url"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--channel")
    try:
        return p.parse_args(argv)
    except SystemExit:
        sys.exit(64)


def load(path):
    if os.path.exists(path):
        return ET.parse(path)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "MacExplorer"
    ET.SubElement(channel, "link").text = "https://roniburd.github.io/macExplorer/appcast.xml"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def main(argv):
    a = parse_args(argv)
    tree = load(a.appcast)
    channel = tree.getroot().find("channel")
    for old in channel.findall("item"):
        if old.findtext(S + "version") == a.build:
            channel.remove(old)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "MacExplorer " + a.version
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, S + "version").text = a.build
    ET.SubElement(item, S + "shortVersionString").text = a.version
    ET.SubElement(item, S + "minimumSystemVersion").text = a.min_os
    ET.SubElement(item, S + "releaseNotesLink").text = a.notes_url
    if a.channel:
        ET.SubElement(item, S + "channel").text = a.channel
    ET.SubElement(item, "enclosure", {"url": a.url, "length": a.length, "type": "application/octet-stream",
                                      S + "edSignature": a.ed_signature})
    first = next((i for i, e in enumerate(list(channel)) if e.tag == "item"), len(channel))
    channel.insert(first, item)
    ET.indent(tree, space="  ")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(a.appcast)), suffix=".xml")
    with os.fdopen(fd, "wb") as f:
        tree.write(f, encoding="utf-8", xml_declaration=True)
    os.replace(tmp, a.appcast)


if __name__ == "__main__":
    main(sys.argv[1:])
