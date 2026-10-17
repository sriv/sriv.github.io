#!/usr/bin/env python3
"""Generate the agent-facing files from _posts/.

Writes, at the repo root (served as static files by GitHub Pages):
  llms.txt         - an index of the site in the llms.txt format
  llms-full.txt    - every note as plain markdown, in one file
  notes/<slug>.md  - each note as plain markdown, next to its HTML page

Diagrams are replaced by their text description so nothing is lost.
Run before committing a new or edited note:  python3 scripts/build_agent_files.py
"""
import glob
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = "https://sriv.github.io"
AUTHOR = "Srikanth Venugopalan"


def front_matter(text):
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    meta = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip().strip('"')
    return meta, m.group(2)


def diagram_text(name):
    path = os.path.join(ROOT, "_includes", "diagrams", name)
    svg = open(path).read()
    title = re.search(r"<title[^>]*>(.*?)</title>", svg, re.S)
    caption = re.search(r"<figcaption>(.*?)</figcaption>", svg, re.S)
    out = "[Diagram: " + (title.group(1).strip() if title else name) + "]"
    if caption:
        out += "\n\n*" + caption.group(1).strip() + "*"
    return out


def to_markdown(body):
    body = re.sub(r"\{%\s*include diagrams/([\w.-]+)\s*%\}", lambda m: diagram_text(m.group(1)), body)
    # make site-relative links absolute so the text stands on its own
    return re.sub(r"\]\((/[^)]*)\)", lambda m: "](" + SITE + m.group(1) + ")", body).strip()


notes = []
for path in glob.glob(os.path.join(ROOT, "_posts", "*.md")):
    meta, body = front_matter(open(path).read())
    if "chapter" not in meta:
        continue  # the 2012-13 archive posts are not part of the notes
    slug = re.sub(r"^\d{4}-\d\d-\d\d-", "", os.path.basename(path))[:-3]
    notes.append(dict(meta, slug=slug, body=to_markdown(body), order=int(meta["chapter"])))
notes.sort(key=lambda n: n["order"], reverse=True)

os.makedirs(os.path.join(ROOT, "notes"), exist_ok=True)
full = []
for n in notes:
    url = f"{SITE}/notes/{n['slug']}/"
    doc = (f"# {n['title']}\n\n"
           f"By {AUTHOR}, {n['period']}. Topics: {n.get('tags', '').strip('[]')}.\n"
           f"Canonical: {url}\n\n"
           f"> {n.get('dek', '')}\n\n{n['body']}\n")
    open(os.path.join(ROOT, "notes", n["slug"] + ".md"), "w").write(doc)
    full.append(doc)

intro = f"""# Hack n Learn

> Notes by {AUTHOR} on building a distributed, petabyte-scale analytical query engine, and on the architecture around it: query execution, indexing, vector search, lakehouse storage (Apache Iceberg, Parquet), distributed and multi-cloud execution, and what data systems need as AI agents become their users.

The author works on OLAP query engines at e6data. Each note is written from first-hand engineering work and dated to when the work happened. Earlier writing (2012 to 2013) is also on the site.

Every note is available as plain markdown by replacing the trailing slash of its URL with `.md`, and all of them together at {SITE}/llms-full.txt.

## Notes

"""
lines = [f"- [{n['title']}]({SITE}/notes/{n['slug']}.md): {n['period']}. {n.get('dek', '')}" for n in notes]
about = f"""

## About

- [About the author]({SITE}/about/): background, current focus, open-source work (lead developer of Gauge, 2015 to 2021).
- [Atom feed]({SITE}/atom.xml)
- [GitHub](https://github.com/sriv)
- [LinkedIn](https://www.linkedin.com/in/srikanth-v-6393b922/)
"""
open(os.path.join(ROOT, "llms.txt"), "w").write(intro + "\n".join(lines) + about)
open(os.path.join(ROOT, "llms-full.txt"), "w").write(
    intro.split("## Notes")[0] + "\n---\n\n" + "\n---\n\n".join(full))
print(f"wrote llms.txt, llms-full.txt and {len(notes)} notes/*.md")
