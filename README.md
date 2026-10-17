# sriv.github.io

Source for my site. GitHub Pages builds it with Jekyll on push.

Local preview:

    docker run --rm -p 4000:4000 -v "$PWD":/srv -w /srv ruby:3.3 \
      sh -c "bundle install && bundle exec jekyll serve --host 0.0.0.0"

Notes live in `_posts/` with `period:` and `dek:` in the front matter.
Diagrams are inline SVG includes in `_includes/diagrams/`.

After adding or editing a note, regenerate the agent-facing files (llms.txt, llms-full.txt, notes/*.md):

    python3 scripts/build_agent_files.py
